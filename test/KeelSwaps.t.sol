// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {KeelTestBase} from "./helpers/KeelTestBase.sol";
import {V4Actor} from "./helpers/V4Actor.sol";
import {KeelRouter} from "../src/KeelRouter.sol";
import {KeelConstants as C} from "../src/libraries/KeelConstants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract KeelSwapsTest is KeelTestBase {
    using PoolIdLibrary for PoolKey;
    V4Actor internal actor;

    function setUp() public override {
        super.setUp();
        actor = new V4Actor(IPoolManager(C.POOL_MANAGER));
        imd.mint(address(actor), 1e27);
    }

    function _params(bool zeroForOne, int256 amount) internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams(
            zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _ethPool() internal returns (PoolKey memory key) {
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(C.IMD), 10000, 200, IHooks(address(0)));
        assertEq(manager.initialize(key, TickMath.getSqrtPriceAtTick(0)), 0);
        vm.deal(address(actor), 1e27);
        actor.modify(key, IPoolManager.ModifyLiquidityParams(-20000, 20000, 1e24, bytes32(0)));
        router.setEthPool(10000, 200);
        vm.deal(alice, 1e24);
    }

    function testExactOutputBuyChargesIMDOnTop() public {
        uint256 desired = 1e23;
        uint256 before = imd.balanceOf(address(actor));
        BalanceDelta d = actor.swap(factory.poolKey(token), _params(false, int256(desired)));
        assertEq(d.amount0(), int256(desired));
        uint256 paid = before - imd.balanceOf(address(actor));
        uint256 fee = hook.pending(token);
        assertEq(fee, Math.ceilDiv(paid - fee, 99));
        assertEq(uint256(-int256(d.amount1())), paid);
        assertEq(IERC20(token).balanceOf(address(actor)), desired);
        hook.distribute(token);
        _solvent();
    }

    function testExactOutputSellDeliversNetIMDAfterFee() public {
        actor.swap(factory.poolKey(token), _params(false, -int256(100 ether)));
        hook.distribute(token);
        uint256 before = imd.balanceOf(address(actor));
        BalanceDelta d = actor.swap(factory.poolKey(token), _params(true, int256(1 ether)));
        assertEq(d.amount1(), 1 ether);
        assertLt(d.amount0(), 0);
        assertEq(imd.balanceOf(address(actor)), before + 1 ether);
        assertEq(hook.pending(token), Math.ceilDiv(1 ether, 99));
        hook.distribute(token);
        _solvent();
    }

    function testExactInputSellFeeComesFromGrossIMDOutput() public {
        actor.swap(factory.poolKey(token), _params(false, -int256(100 ether)));
        hook.distribute(token);
        uint256 sold = IERC20(token).balanceOf(address(actor)) / 2;
        BalanceDelta d = actor.swap(factory.poolKey(token), _params(true, -int256(sold)));
        uint256 received = uint256(uint128(d.amount1()));
        uint256 fee = hook.pending(token);
        assertEq(fee, (received + fee) / 100);
        assertEq(-int256(d.amount0()), int256(sold));
    }

    function testSpecifiedIMDPartialFillRevertsAtomically() public {
        PoolKey memory key = factory.poolKey(token);
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams(false, -int256(1000 ether), TickMath.getSqrtPriceAtTick(-99799));
        vm.expectRevert();
        actor.swap(key, params);
        assertEq(hook.pending(token), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(C.IMD))), 0);
    }

    function testOnlyFactoryCanInitializeAndAddLiquidityAndPositionCannotBeRemoved() public {
        PoolKey memory key = factory.poolKey(token);
        key.currency0 = Currency.wrap(alice);
        assertLt(uint160(alice), uint160(C.IMD));
        vm.expectRevert();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(-100000));
        key = factory.poolKey(token);
        int24 lower = factory.lowerTick(token);
        vm.expectRevert();
        actor.modify(key, IPoolManager.ModifyLiquidityParams(lower, C.MAX_TICK, 1, bytes32(0)));
        vm.expectRevert();
        actor.modify(key, IPoolManager.ModifyLiquidityParams(lower, C.MAX_TICK, -1, bytes32(0)));
    }

    function testETHUnconfiguredThenConfiguredBuyAndSellWithQuote() public {
        vm.expectRevert(KeelRouter.EthPoolNotConfigured.selector);
        router.quoteExactInput(address(0), token, 1 ether);
        vm.expectRevert(KeelRouter.InvalidPool.selector);
        router.setEthPool(10000, 200);
        _ethPool();
        uint256 quoted = router.quoteExactInput(address(0), token, 100 ether);
        vm.prank(alice);
        uint256 bought = router.swapExactInput{value: 100 ether}(
            address(0), token, 100 ether, quoted, block.timestamp, alice
        );
        assertEq(bought, quoted);
        quoted = router.quoteExactInput(token, address(0), bought / 2);
        vm.startPrank(alice);
        IERC20(token).approve(address(router), bought / 2);
        uint256 before = alice.balance;
        uint256 out = router.swapExactInput(token, address(0), bought / 2, quoted, block.timestamp, alice);
        vm.stopPrank();
        assertEq(out, quoted);
        assertEq(alice.balance, before + out);
        assertEq(address(router).balance, 0);
        assertEq(imd.balanceOf(address(router)), 0);
        hook.distribute(token);
        _solvent();
    }

    function testETHAndIMDDirectRoutesAndValueValidation() public {
        _ethPool();
        uint256 quote = router.quoteExactInput(address(0), C.IMD, 5 ether);
        vm.startPrank(alice);
        uint256 out =
            router.swapExactInput{value: 5 ether}(address(0), C.IMD, 5 ether, quote, block.timestamp, alice);
        assertEq(out, quote);
        quote = router.quoteExactInput(C.IMD, address(0), 5 ether);
        assertEq(router.swapExactInput(C.IMD, address(0), 5 ether, quote, block.timestamp, alice), quote);
        vm.expectRevert(KeelRouter.InvalidAmount.selector);
        router.swapExactInput{value: 1}(C.IMD, token, 1 ether, 1, block.timestamp, alice);
        vm.expectRevert(KeelRouter.InvalidAmount.selector);
        router.swapExactInput{value: 1}(address(0), token, 1 ether, 1, block.timestamp, alice);
        vm.stopPrank();
        assertEq(hook.pending(token), 0);
    }

    function testTokenToTokenRoutesThroughIMDAndAccruesToBothProjects() public {
        address other = _launch(bob, JOB2, 8000, -99901);
        uint256 bought = _buy(alice, 100 ether);
        uint256 quote = router.quoteExactInput(token, other, bought / 2);
        vm.startPrank(alice);
        IERC20(token).approve(address(router), bought / 2);
        uint256 out = router.swapExactInput(token, other, bought / 2, quote, block.timestamp, alice);
        vm.stopPrank();
        assertEq(out, quote);
        assertGt(hook.pending(token), 1 ether);
        assertGt(hook.pending(other), 0);
        hook.distribute(token);
        hook.distribute(other);
        assertEq(imd.balanceOf(address(vault)), vault.totalOwed());
    }

    function testQuotesIncludeProtocolFeeAndCrossMultipleRanges() public {
        PoolKey memory key = _ethPool();
        actor.modify(key, IPoolManager.ModifyLiquidityParams(-200, 200, 1e23, bytes32(uint256(1))));
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, uint24(700 | (900 << 12)));
        manager.setProtocolFee(factory.poolKey(token), uint24(500 | (1000 << 12)));
        uint256 amount = 1e23;
        uint256 quoted = router.quoteExactInput(address(0), token, amount);
        vm.prank(alice);
        uint256 bought =
            router.swapExactInput{value: amount}(address(0), token, amount, quoted, block.timestamp, alice);
        assertEq(bought, quoted);
        quoted = router.quoteExactInput(token, address(0), bought / 2);
        vm.startPrank(alice);
        IERC20(token).approve(address(router), bought / 2);
        assertEq(router.swapExactInput(token, address(0), bought / 2, quoted, block.timestamp, alice), quoted);
        vm.stopPrank();
    }

    function testRouterTransferCallbackCannotReenter() public {
        imd.setCallback(
            address(router),
            abi.encodeCall(router.swapExactInput, (C.IMD, token, 1 ether, 1, block.timestamp, alice))
        );
        _buy(alice, 100 ether);
        assertFalse(imd.callbackSucceeded());
        assertEq(hook.pending(token), 1 ether);
    }
}
