// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {KeelTestBase} from "./helpers/KeelTestBase.sol";
import {KeelVault} from "../src/KeelVault.sol";
import {KeelToken} from "../src/KeelToken.sol";
import {KeelHook} from "../src/KeelHook.sol";
import {KeelRouter} from "../src/KeelRouter.sol";
import {KeelConstants as C} from "../src/libraries/KeelConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract KeelIntegrationTest is KeelTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function testLaunchLocksSupplyAndMinesExactHookBits() public view {
        assertEq(uint160(address(hook)) & 0x3fff, 0x28cc);
        assertLt(uint160(token), uint160(C.IMD));
        assertEq(IERC20(token).totalSupply(), 1e27);
        assertEq(IERC20(token).balanceOf(address(factory)), 0);
        assertEq(IERC20(token).balanceOf(C.POOL_MANAGER) + IERC20(token).balanceOf(C.DEAD), 1e27);
        assertGt(IERC20(token).balanceOf(C.POOL_MANAGER), 1e27 - 1e10);
        assertGt(factory.lockedLiquidity(token), 0);
        assertEq(factory.lowerTick(token), -99800);
        assertEq(vault.buildingToken(creator), token);
        assertEq(vault.project(token).creator, creator);
    }

    function testBuySellQuoteAndFeeConservation() public {
        uint256 quoted = router.quoteExactInput(C.IMD, token, 100 ether);
        uint256 bought = _buy(alice, 100 ether);
        assertEq(bought, quoted);
        assertEq(hook.pending(token), 1 ether);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(C.IMD))), 1 ether);
        uint256 sellQuote = router.quoteExactInput(token, C.IMD, bought / 2);
        assertEq(_sell(alice, bought / 2), sellQuote);
        uint256 fees = hook.pending(token);
        hook.distribute(token);
        assertEq(hook.pending(token), 0);
        assertEq(hook.totalPending(), 0);
        assertEq(imd.balanceOf(address(vault)), fees);
        KeelVault.Project memory p = vault.project(token);
        assertEq(vault.teamAccrued(), fees / 10);
        assertEq(p.creatorAccrued, fees * 3000 / 10000);
        assertEq(p.basket + p.creatorAccrued + vault.teamAccrued(), fees);
        _solvent();
    }

    function testLowerShareDistributesAtOldShare() public {
        _buy(alice, 100 ether);
        vm.prank(creator);
        vault.lowerCreatorShare(token, 1000);
        KeelVault.Project memory p = vault.project(token);
        assertEq(p.creatorAccrued, 0.3 ether);
        assertEq(p.basket, 0.6 ether);
        _buy(alice, 100 ether);
        hook.distribute(token);
        p = vault.project(token);
        assertEq(p.creatorAccrued, 0.4 ether);
        assertEq(p.basket, 1.4 ether);
        vm.prank(creator);
        vm.expectRevert(KeelVault.InvalidShare.selector);
        vault.lowerCreatorShare(token, 1001);
        vm.prank(creator);
        vm.expectRevert(KeelVault.InvalidShare.selector);
        vault.lowerCreatorShare(token, 1000);
        vm.prank(bob);
        vm.expectRevert(KeelVault.Unauthorized.selector);
        vault.lowerCreatorShare(token, 0);
    }

    function testInactiveCreatorAndReactivationDistributeUnderPreviousStatus() public {
        _buy(alice, 100 ether);
        vault.setCreatorActive(token, false);
        assertEq(vault.project(token).creatorAccrued, 0.3 ether);
        _buy(alice, 100 ether);
        vault.setCreatorActive(token, true);
        assertEq(vault.project(token).creatorAccrued, 0.3 ether);
        assertEq(vault.project(token).basket, 1.5 ether);
        _buy(alice, 100 ether);
        hook.distribute(token);
        assertEq(vault.project(token).creatorAccrued, 0.6 ether);
    }

    function testCloseFlushesFeesThenNewFeesPayCreatorEvenInactive() public {
        _buy(alice, 100 ether);
        vault.setCreatorActive(token, false);
        _buy(alice, 100 ether);
        _matureClose();
        KeelVault.Project memory p = vault.project(token);
        assertEq(p.poolAtClose, 1.5 ether);
        assertEq(p.basket, 1.5 ether);
        _buy(bob, 100 ether);
        hook.distribute(token);
        p = vault.project(token);
        assertEq(p.creatorAccrued, 1.2 ether);
        assertEq(p.poolAtClose, 1.5 ether);
        assertEq(p.basket, 1.5 ether);
        assertEq(vault.teamAccrued(), 0.3 ether);
        vm.prank(creator);
        vault.claimCreator(token);
        assertEq(imd.balanceOf(creator), 1.2 ether);
        uint256 before = imd.balanceOf(address(this));
        vault.claimTeam();
        assertEq(imd.balanceOf(address(this)), before + 0.3 ether);
        _solvent();
    }

    function testNoAllowanceTheftThroughCallback() public {
        bytes memory forged = abi.encode(KeelRouter.Request(C.IMD, token, 100 ether, 1, bob));
        uint256 before = imd.balanceOf(alice);
        vm.prank(bob);
        vm.expectRevert(KeelRouter.InvalidCallback.selector);
        router.unlockCallback(forged);
        vm.prank(C.POOL_MANAGER);
        vm.expectRevert(KeelRouter.InvalidCallback.selector);
        router.unlockCallback(forged);
        vm.prank(bob);
        router.swapExactInput(C.IMD, token, 100 ether, 1, block.timestamp, bob);
        assertEq(imd.balanceOf(alice), before);
        assertEq(imd.balanceOf(address(router)), 0);
    }

    function testRouterRejectsExpiredSlippageAndInvalidRoutes() public {
        vm.startPrank(alice);
        vm.expectRevert(KeelRouter.Expired.selector);
        router.swapExactInput(C.IMD, token, 1 ether, 1, block.timestamp - 1, alice);
        vm.expectRevert(KeelRouter.Slippage.selector);
        router.swapExactInput(C.IMD, token, 1 ether, 0, block.timestamp, alice);
        vm.expectRevert(KeelRouter.Slippage.selector);
        router.swapExactInput(C.IMD, token, 1 ether, 1e27, block.timestamp, alice);
        vm.expectRevert(KeelRouter.InvalidRoute.selector);
        router.swapExactInput(C.IMD, C.IMD, 1 ether, 1, block.timestamp, alice);
        vm.expectRevert(KeelRouter.InvalidRoute.selector);
        router.swapExactInput(C.IMD, bob, 1 ether, 1, block.timestamp, alice);
        vm.expectRevert(KeelRouter.InvalidAmount.selector);
        router.swapExactInput(C.IMD, token, 0, 1, block.timestamp, alice);
        vm.expectRevert(KeelRouter.InvalidAddress.selector);
        router.swapExactInput(C.IMD, token, 1 ether, 1, block.timestamp, address(router));
        vm.stopPrank();
        assertEq(hook.pending(token), 0);
    }

    function testHookAndFactoryCallbacksRejectDirectCall() public {
        vm.expectRevert(KeelHook.Unauthorized.selector);
        hook.unlockCallback(abi.encode(1 ether));
        vm.prank(C.POOL_MANAGER);
        vm.expectRevert(KeelHook.InvalidCallback.selector);
        hook.unlockCallback(abi.encode(1 ether));
        vm.expectRevert();
        factory.unlockCallback(abi.encode(token));
        vm.prank(C.POOL_MANAGER);
        vm.expectRevert();
        factory.unlockCallback(abi.encode(token));
    }

    function testDistributionFailureRestoresPendingClaimsAndAccounting() public {
        _buy(alice, 100 ether);
        imd.setFailTransfers(true);
        vm.expectRevert();
        hook.distribute(token);
        assertEq(hook.pending(token), 1 ether);
        assertEq(hook.totalPending(), 1 ether);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(C.IMD))), 1 ether);
        assertEq(vault.totalOwed(), 0);
        imd.setFailTransfers(false);
        hook.distribute(token);
        assertEq(vault.totalOwed(), 1 ether);
        _solvent();
    }

    function testFuzzFeeSplitConservesEveryWei(uint96 rawAmount, uint16 rawBps, bool active) public {
        uint256 amount = bound(rawAmount, 100, 1e22);
        uint256 bps = bound(rawBps, 0, 8000);
        address other = _launch(bob, JOB2, bps, -100000);
        if (!active) vault.setCreatorActive(other, false);
        vm.prank(alice);
        router.swapExactInput(C.IMD, other, amount, 1, block.timestamp, alice);
        uint256 fee = amount / 100;
        assertEq(hook.pending(other), fee);
        hook.distribute(other);
        KeelVault.Project memory p = vault.project(other);
        uint256 creatorFee = active ? fee * bps / 10000 : 0;
        assertEq(vault.teamAccrued(), fee / 10);
        assertEq(p.creatorAccrued, creatorFee);
        assertEq(p.basket, fee - fee / 10 - creatorFee);
        assertEq(vault.totalOwed(), fee);
        assertEq(imd.balanceOf(address(vault)), fee);
    }

    function testFuzzQuoteMatchesBuySell(uint96 amount) public {
        uint256 input = bound(amount, 1e6, 1e22);
        uint256 buyQuote = router.quoteExactInput(C.IMD, token, input);
        uint256 bought = _buy(alice, input);
        assertEq(bought, buyQuote);
        uint256 sellQuote = router.quoteExactInput(token, C.IMD, bought / 2);
        assertEq(_sell(alice, bought / 2), sellQuote);
        hook.distribute(token);
        _solvent();
    }
}
