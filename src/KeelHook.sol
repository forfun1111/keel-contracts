// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IKeelVault} from "./interfaces/IKeel.sol";
import {KeelConstants as C} from "./libraries/KeelConstants.sol";

/// @notice Fees are denominated in IMD and backed by PoolManager ERC-6909 claims.
/// @dev Unpermissioned hook selectors are deliberately absent and revert.
contract KeelHook is ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    IPoolManager public constant poolManager = IPoolManager(C.POOL_MANAGER);
    address public immutable factory;
    address public immutable vault;
    mapping(PoolId => address) public tokenForPool;
    mapping(address => bool) public registered;
    mapping(address => uint256) public pending;
    uint256 public totalPending;
    uint256 private _distributionAmount;

    error Unauthorized();
    error InvalidAddress();
    error InvalidPool();
    error InvalidAmount();
    error PartialFill();
    error InvalidCallback();

    event FeePending(address indexed token, uint256 amount, uint256 pendingTotal);
    event FeesDistributed(address indexed token, uint256 amount);

    constructor(address factory_, address vault_) {
        if (factory_ == address(0) || vault_ == address(0)) revert InvalidAddress();
        factory = factory_;
        vault = vault_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyManager() {
        if (msg.sender != C.POOL_MANAGER) revert Unauthorized();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        onlyManager
        returns (bytes4)
    {
        if (sender != factory) revert Unauthorized();
        address token = Currency.unwrap(key.currency0);
        if (
            token == address(0) || token >= C.IMD || Currency.unwrap(key.currency1) != C.IMD || key.fee != 0
                || key.tickSpacing != C.TICK_SPACING || address(key.hooks) != address(this)
                || registered[token]
        ) revert InvalidPool();
        tokenForPool[key.toId()] = token;
        registered[token] = true;
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyManager returns (bytes4) {
        if (sender != factory) revert Unauthorized();
        _token(key);
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external onlyManager returns (bytes4, BeforeSwapDelta, uint24) {
        address token = _token(key);
        if (
            params.amountSpecified == 0 || params.amountSpecified > type(int128).max
                || params.amountSpecified < -int256(type(int128).max)
        ) revert InvalidAmount();
        uint256 fee = 0;
        if (_imdSpecified(params)) {
            fee = _specifiedFee(params.amountSpecified);
            _collect(token, fee);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(SafeCast.toInt128(int256(fee)), 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyManager returns (bytes4, int128) {
        address token = _token(key);
        if (_imdSpecified(params)) {
            // Do not charge a fee on an unfilled IMD budget, or deliver less than an exact output.
            if (
                int256(delta.amount1())
                    != params.amountSpecified + int256(_specifiedFee(params.amountSpecified))
            ) {
                revert PartialFill();
            }
            return (IHooks.afterSwap.selector, 0);
        }
        int256 imdDelta = int256(delta.amount1());
        uint256 fee = imdDelta < 0 ? Math.ceilDiv(uint256(-imdDelta), 99) : uint256(imdDelta) / 100;
        _collect(token, fee);
        return (IHooks.afterSwap.selector, SafeCast.toInt128(int256(fee)));
    }

    function distribute(address token) external nonReentrant {
        if (!registered[token]) revert InvalidPool();
        uint256 amount = pending[token];
        if (amount == 0) return;
        pending[token] = 0;
        totalPending -= amount;
        _distributionAmount = amount;
        emit FeesDistributed(token, amount);
        bytes memory result = poolManager.unlock(abi.encode(amount));
        if (abi.decode(result, (uint256)) != amount || _distributionAmount != 0) revert InvalidCallback();
        IERC20(C.IMD).safeTransfer(vault, amount);
        IKeelVault(vault).accrue(token, amount);
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        uint256 amount = abi.decode(data, (uint256));
        if (amount == 0 || amount != _distributionAmount) revert InvalidCallback();
        _distributionAmount = 0;
        poolManager.burn(address(this), uint256(uint160(C.IMD)), amount);
        poolManager.take(Currency.wrap(C.IMD), address(this), amount);
        return abi.encode(amount);
    }

    function _collect(address token, uint256 amount) private {
        if (amount == 0) return;
        pending[token] += amount;
        totalPending += amount;
        emit FeePending(token, amount, pending[token]);
        poolManager.mint(address(this), uint256(uint160(C.IMD)), amount);
    }

    function _token(PoolKey calldata key) private view returns (address token) {
        token = tokenForPool[key.toId()];
        if (token == address(0)) revert InvalidPool();
    }

    function _imdSpecified(IPoolManager.SwapParams calldata params) private pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified > 0);
    }

    function _specifiedFee(int256 amount) private pure returns (uint256) {
        // Exact input: floor(1% of the gross input). Exact output: gross up the net IMD output.
        return amount < 0 ? uint256(-amount) / 100 : Math.ceilDiv(uint256(amount), 99);
    }
}
