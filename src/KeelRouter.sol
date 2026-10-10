// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IKeelFactory} from "./interfaces/IKeel.sol";
import {KeelConstants as C} from "./libraries/KeelConstants.sol";
import {V4Quote} from "./libraries/V4Quote.sol";

contract KeelRouter is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    struct Request {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minimumOut;
        address recipient;
    }

    IPoolManager public constant poolManager = IPoolManager(C.POOL_MANAGER);
    IKeelFactory public immutable factory;
    uint24 public ethPoolFee = 10000;
    int24 public ethPoolTickSpacing = 200;
    bool public ethPoolConfigured;
    bytes32 private _callbackHash;

    error InvalidAddress();
    error InvalidRoute();
    error InvalidAmount();
    error Expired();
    error EthPoolNotConfigured();
    error InvalidPool();
    error InvalidCallback();
    error PartialFill();
    error Slippage();
    error SettlementMismatch();

    event EthPoolSet(bytes32 indexed poolId, uint24 fee, int24 tickSpacing);
    event Swapped(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        address recipient,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(address owner_, address factory_) Ownable(owner_) {
        if (factory_ == address(0)) revert InvalidAddress();
        factory = IKeelFactory(factory_);
    }

    /// @notice Select an existing hookless native ETH/IMD pool; the default parameters are 10000/200.
    function setEthPool(uint256 fee, uint256 tickSpacing) external onlyOwner nonReentrant {
        if (fee >= 1000000 || tickSpacing == 0 || tickSpacing > uint256(uint16(type(int16).max))) {
            revert InvalidPool();
        }
        PoolKey memory key = _ethKey(uint24(fee), int24(uint24(tickSpacing)));
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) =
            StateLibrary.getSlot0(poolManager, key.toId());
        if (
            price == 0 || lpFee != fee || tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK
                || protocolFee & 0xfff > 1000 || protocolFee >> 12 > 1000
        ) revert InvalidPool();
        ethPoolFee = uint24(fee);
        ethPoolTickSpacing = int24(uint24(tickSpacing));
        ethPoolConfigured = true;
        emit EthPoolSet(PoolId.unwrap(key.toId()), uint24(fee), int24(uint24(tickSpacing)));
    }

    /// @notice address(0) denotes native ETH. Every supported route consumes the full input or reverts.
    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minimumOut,
        uint256 deadline,
        address recipient
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        _validate(tokenIn, tokenOut, amountIn);
        if (recipient == address(0) || recipient == address(this) || recipient == C.POOL_MANAGER) {
            revert InvalidAddress();
        }
        if (minimumOut == 0) revert Slippage();
        if (tokenIn == address(0)) {
            if (msg.value != amountIn) revert InvalidAmount();
        } else {
            if (msg.value != 0) revert InvalidAmount();
            uint256 beforeBalance = IERC20(tokenIn).balanceOf(address(this));
            // The only transferFrom in this router always uses the authenticated external caller.
            // Callback data never supplies a payer and the callback only spends these escrowed funds.
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            if (IERC20(tokenIn).balanceOf(address(this)) != beforeBalance + amountIn) {
                revert SettlementMismatch();
            }
        }
        bytes memory data = abi.encode(Request(tokenIn, tokenOut, amountIn, minimumOut, recipient));
        _callbackHash = keccak256(data);
        amountOut = abi.decode(poolManager.unlock(data), (uint256));
        if (_callbackHash != bytes32(0) || amountOut < minimumOut) revert InvalidCallback();
        emit Swapped(msg.sender, tokenIn, tokenOut, recipient, amountIn, amountOut);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != C.POOL_MANAGER || !_reentrancyGuardEntered() || keccak256(data) != _callbackHash) {
            revert InvalidCallback();
        }
        _callbackHash = bytes32(0);
        Request memory r = abi.decode(data, (Request));
        uint256 amountOut = 0;
        if (r.tokenIn == C.IMD || r.tokenOut == C.IMD) {
            amountOut = _swap(r.tokenIn, r.tokenOut, r.amountIn);
        } else {
            uint256 intermediate = _swap(r.tokenIn, C.IMD, r.amountIn);
            amountOut = _swap(C.IMD, r.tokenOut, intermediate);
        }
        if (amountOut < r.minimumOut) revert Slippage();
        poolManager.sync(Currency.wrap(r.tokenIn));
        uint256 settled = 0;
        if (r.tokenIn == address(0)) {
            settled = poolManager.settle{value: r.amountIn}();
        } else {
            IERC20(r.tokenIn).safeTransfer(C.POOL_MANAGER, r.amountIn);
            settled = poolManager.settle();
        }
        if (settled != r.amountIn) revert SettlementMismatch();
        poolManager.take(Currency.wrap(r.tokenOut), r.recipient, amountOut);
        return abi.encode(amountOut);
    }

    /// @notice Current-state execution quote, including Keel, LP and protocol fees. It is not an oracle.
    function quoteExactInput(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256)
    {
        _validate(tokenIn, tokenOut, amountIn);
        if (tokenIn == C.IMD || tokenOut == C.IMD) return _quote(tokenIn, tokenOut, amountIn);
        return _quote(C.IMD, tokenOut, _quote(tokenIn, C.IMD, amountIn));
    }

    function ethPoolKey() external view returns (PoolKey memory) {
        return _ethKey(ethPoolFee, ethPoolTickSpacing);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) private returns (uint256) {
        if (amountIn > uint256(uint128(type(int128).max))) revert InvalidAmount();
        PoolKey memory key = _key(tokenIn, tokenOut);
        bool zeroForOne = tokenIn < tokenOut;
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 input = zeroForOne ? delta.amount0() : delta.amount1();
        int128 output = zeroForOne ? delta.amount1() : delta.amount0();
        if (int256(input) != -int256(amountIn) || output <= 0) revert PartialFill();
        return uint256(uint128(output));
    }

    function _quote(address tokenIn, address tokenOut, uint256 amountIn) private view returns (uint256) {
        PoolKey memory key = _key(tokenIn, tokenOut);
        bool keelPool = tokenIn != address(0) && tokenOut != address(0);
        if (keelPool && tokenIn == C.IMD) amountIn -= amountIn / 100;
        uint256 out = V4Quote.exactInput(poolManager, key, tokenIn < tokenOut, amountIn);
        if (keelPool && tokenOut == C.IMD) out -= out / 100;
        return out;
    }

    function _key(address tokenIn, address tokenOut) private view returns (PoolKey memory) {
        if (tokenIn == address(0) || tokenOut == address(0)) {
            if (!ethPoolConfigured) revert EthPoolNotConfigured();
            return _ethKey(ethPoolFee, ethPoolTickSpacing);
        }
        return factory.poolKey(tokenIn == C.IMD ? tokenOut : tokenIn);
    }

    function _ethKey(uint24 fee, int24 spacing) private pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(C.IMD), fee, spacing, IHooks(address(0)));
    }

    function _validate(address tokenIn, address tokenOut, uint256 amountIn) private view {
        if (tokenIn == tokenOut) revert InvalidRoute();
        if (amountIn == 0 || amountIn > uint256(uint128(type(int128).max))) revert InvalidAmount();
        if (tokenIn != address(0) && tokenIn != C.IMD && !factory.isLaunched(tokenIn)) revert InvalidRoute();
        if (tokenOut != address(0) && tokenOut != C.IMD && !factory.isLaunched(tokenOut)) {
            revert InvalidRoute();
        }
        if ((tokenIn == address(0) || tokenOut == address(0)) && !ethPoolConfigured) {
            revert EthPoolNotConfigured();
        }
    }
}
