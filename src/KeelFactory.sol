// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {IKeelToken, IKeelVault} from "./interfaces/IKeel.sol";
import {KeelHook} from "./KeelHook.sol";
import {KeelConstants as C} from "./libraries/KeelConstants.sol";
import {HookMiner} from "./libraries/HookMiner.sol";
import {Metadata} from "./libraries/Metadata.sol";

contract KeelFactory is Ownable2Step, EIP712, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    IPoolManager public constant poolManager = IPoolManager(C.POOL_MANAGER);
    bytes32 public constant LAUNCH_TYPEHASH = keccak256(
        "Launch(address creator,bytes32 jobRef,bytes32 projectRef,bytes32 nameHash,bytes32 symbolHash,int24 startTick,uint256 deadline)"
    );
    address public immutable vault;
    address public immutable tokenImplementation;
    address public immutable hook;
    bytes32 public immutable hookSalt;
    uint256 public immutable hookSaltAttempts;
    address public signer;
    bool public paused = true;
    bool public tickBoundsSet;
    int24 public minStartTick;
    int24 public maxStartTick;
    mapping(bytes32 => address) public tokenForJob;
    mapping(address => bool) public isLaunched;
    mapping(address => int24) public lowerTick;
    mapping(address => uint128) public lockedLiquidity;
    address private _launchingToken;

    error InvalidAddress();
    error Paused();
    error NotConfigured();
    error Expired();
    error InvalidSignature();
    error InvalidUUID();
    error InvalidName();
    error InvalidTick();
    error InvalidShare();
    error JobAlreadyLaunched();
    error CreatorHasBuildingToken();
    error UnknownToken();
    error InvalidCallback();
    error InvalidLiquidity();

    event HookDeployed(address indexed hook, bytes32 salt, uint256 attempts);
    event SignerSet(address indexed signer);
    event TickBoundsSet(int24 minimum, int24 maximum);
    event PauseSet(bool paused);
    event Launched(
        address indexed token,
        address indexed creator,
        bytes32 indexed jobHash,
        bytes32 projectHash,
        bytes32 poolId,
        string name,
        string symbol,
        string jobRef,
        string projectRef,
        uint256 creatorBps,
        int24 startTick,
        int24 lowerTick,
        uint128 liquidity,
        string metadata
    );

    constructor(address owner_, address vault_, address tokenImplementation_, uint256 hookSaltStart)
        Ownable(owner_)
        EIP712("KeelFactory", "1")
    {
        if (vault_ == address(0) || tokenImplementation_ == address(0)) revert InvalidAddress();
        vault = vault_;
        tokenImplementation = tokenImplementation_;
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(KeelHook).creationCode, abi.encode(address(this), vault_)));
        (bytes32 salt, address predicted, uint256 attempts) =
            HookMiner.find(address(this), initCodeHash, hookSaltStart);
        address deployed = address(new KeelHook{salt: salt}(address(this), vault_));
        assert(deployed == predicted);
        hook = deployed;
        hookSalt = salt;
        hookSaltAttempts = attempts;
        emit HookDeployed(deployed, salt, attempts);
    }

    function setSigner(address signer_) external onlyOwner {
        if (signer_ == address(0)) revert InvalidAddress();
        signer = signer_;
        emit SignerSet(signer_);
    }

    function revokeSigner() external onlyOwner {
        signer = address(0);
        emit SignerSet(address(0));
    }

    function setStartTickBounds(int24 minimum, int24 maximum) external onlyOwner {
        if (minimum < C.MIN_TICK || maximum >= C.MAX_TICK - C.TICK_SPACING || minimum > maximum) {
            revert InvalidTick();
        }
        minStartTick = minimum;
        maxStartTick = maximum;
        tickBoundsSet = true;
        emit TickBoundsSet(minimum, maximum);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PauseSet(paused_);
    }

    function launchDigest(
        address creator,
        bytes32 jobHash,
        bytes32 projectHash,
        bytes32 nameHash,
        bytes32 symbolHash,
        int24 startTick,
        uint256 deadline
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    LAUNCH_TYPEHASH, creator, jobHash, projectHash, nameHash, symbolHash, startTick, deadline
                )
            )
        );
    }

    function launch(
        string calldata name,
        string calldata symbol,
        string calldata jobRef,
        string calldata projectRef,
        uint256 creatorBps,
        int24 startTick,
        uint256 deadline,
        bytes calldata signature,
        string calldata metadata
    ) external nonReentrant returns (address token) {
        if (paused) revert Paused();
        if (signer == address(0) || !tickBoundsSet || IKeelVault(vault).factory() != address(this)) {
            revert NotConfigured();
        }
        if (block.timestamp > deadline) revert Expired();
        if (
            bytes(name).length == 0 || bytes(name).length > 128 || bytes(symbol).length == 0
                || bytes(symbol).length > 32
        ) revert InvalidName();
        _uuid(jobRef);
        _uuid(projectRef);
        Metadata.validate(metadata);
        if (creatorBps > 8000) revert InvalidShare();
        if (startTick < minStartTick || startTick > maxStartTick) revert InvalidTick();
        bytes32 jobHash = keccak256(bytes(jobRef));
        bytes32 projectHash = keccak256(bytes(projectRef));
        if (tokenForJob[jobHash] != address(0)) revert JobAlreadyLaunched();
        if (IKeelVault(vault).buildingToken(msg.sender) != address(0)) revert CreatorHasBuildingToken();
        if (!SignatureChecker.isValidSignatureNow(
                signer,
                launchDigest(
                    msg.sender,
                    jobHash,
                    projectHash,
                    keccak256(bytes(name)),
                    keccak256(bytes(symbol)),
                    startTick,
                    deadline
                ),
                signature
            )) revert InvalidSignature();

        // A token0-only position lies above the start price. Mine the clone below the fixed IMD address.
        bytes32 cloneSalt = jobHash;
        uint256 nonce = 0;
        while (Clones.predictDeterministicAddress(tokenImplementation, cloneSalt) >= C.IMD) {
            cloneSalt = keccak256(abi.encode(jobHash, ++nonce));
        }
        token = Clones.cloneDeterministic(tokenImplementation, cloneSalt);
        tokenForJob[jobHash] = token;
        isLaunched[token] = true;
        IKeelToken(token).initialize(name, symbol, address(this));
        if (IERC20(token).balanceOf(address(this)) != C.SUPPLY) revert InvalidLiquidity();

        int24 compressed = startTick / C.TICK_SPACING;
        if (startTick < 0 && startTick % C.TICK_SPACING != 0) --compressed;
        int24 lower = (compressed + 1) * C.TICK_SPACING;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(C.MAX_TICK);
        uint256 liquidity = FullMath.mulDiv(
            C.SUPPLY, FullMath.mulDiv(sqrtLower, sqrtUpper, 1 << 96), uint256(sqrtUpper) - sqrtLower
        );
        if (liquidity == 0 || liquidity > Pool.tickSpacingToMaxLiquidityPerTick(C.TICK_SPACING)) {
            revert InvalidLiquidity();
        }
        lowerTick[token] = lower;
        lockedLiquidity[token] = SafeCast.toUint128(liquidity);
        IKeelVault(vault).register(token, msg.sender, jobHash, projectHash, creatorBps);
        PoolKey memory key = poolKey(token);
        int24 initializedTick = poolManager.initialize(key, TickMath.getSqrtPriceAtTick(startTick));
        if (initializedTick != startTick) revert InvalidTick();
        _launchingToken = token;
        bytes memory result = poolManager.unlock(abi.encode(token));
        uint256 spent = abi.decode(result, (uint256));
        if (_launchingToken != address(0) || spent == 0 || spent > C.SUPPLY) revert InvalidCallback();
        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust != C.SUPPLY - spent) revert InvalidLiquidity();
        if (dust != 0) IERC20(token).safeTransfer(C.DEAD, dust);
        emit Launched(
            token,
            msg.sender,
            jobHash,
            projectHash,
            PoolId.unwrap(key.toId()),
            name,
            symbol,
            jobRef,
            projectRef,
            creatorBps,
            startTick,
            lower,
            uint128(liquidity),
            metadata
        );
    }

    function poolKey(address token) public view returns (PoolKey memory) {
        if (!isLaunched[token]) revert UnknownToken();
        return PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(C.IMD),
            fee: 0,
            tickSpacing: C.TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != C.POOL_MANAGER) revert InvalidCallback();
        address token = abi.decode(data, (address));
        if (token == address(0) || token != _launchingToken) revert InvalidCallback();
        _launchingToken = address(0);
        (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(
            poolKey(token),
            IPoolManager.ModifyLiquidityParams({
                tickLower: lowerTick[token],
                tickUpper: C.MAX_TICK,
                liquidityDelta: int256(uint256(lockedLiquidity[token])),
                salt: bytes32(0)
            }),
            ""
        );
        if (BalanceDelta.unwrap(fees) != 0 || delta.amount0() >= 0 || delta.amount1() != 0) {
            revert InvalidLiquidity();
        }
        uint256 amount = uint256(-int256(delta.amount0()));
        poolManager.sync(Currency.wrap(token));
        IERC20(token).safeTransfer(C.POOL_MANAGER, amount);
        if (poolManager.settle() != amount) revert InvalidLiquidity();
        return abi.encode(amount);
    }

    function _uuid(string calldata value) private pure {
        bytes calldata b = bytes(value);
        if (b.length != 36) revert InvalidUUID();
        for (uint256 i = 0; i < 36; ++i) {
            bytes1 c = b[i];
            if (i == 8 || i == 13 || i == 18 || i == 23) {
                if (c != "-") revert InvalidUUID();
            } else if (!((c >= "0" && c <= "9") || (c >= "a" && c <= "f"))) {
                revert InvalidUUID();
            }
        }
    }
}
