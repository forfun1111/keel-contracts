// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Test-only raw v4 swapper / liquidity provider, funded directly by test fixtures.
contract V4Actor is IUnlockCallback {
    using SafeERC20 for IERC20;
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }
    receive() external payable {}

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint256(0), key, abi.encode(params))), (BalanceDelta));
    }

    function modify(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        external
        returns (BalanceDelta)
    {
        return abi.decode(manager.unlock(abi.encode(uint256(1), key, abi.encode(params))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint256 kind, PoolKey memory key, bytes memory params) = abi.decode(data, (uint256, PoolKey, bytes));
        BalanceDelta delta = BalanceDelta.wrap(0);
        if (kind == 0) {
            delta = manager.swap(key, abi.decode(params, (IPoolManager.SwapParams)), "");
        } else {
            (BalanceDelta d, BalanceDelta fees) =
                manager.modifyLiquidity(key, abi.decode(params, (IPoolManager.ModifyLiquidityParams)), "");
            delta = d;
            require(fees.amount0() >= 0 && fees.amount1() >= 0);
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta > 0) manager.take(currency, address(this), uint256(uint128(delta)));
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            uint256 settled = 0;
            if (Currency.unwrap(currency) == address(0)) {
                settled = manager.settle{value: amount}();
            } else {
                IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), amount);
                settled = manager.settle();
            }
            require(settled == amount);
        }
    }
}
