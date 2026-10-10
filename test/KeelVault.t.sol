// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {KeelTestBase} from "./helpers/KeelTestBase.sol";
import {KeelVault} from "../src/KeelVault.sol";
import {KeelFactory} from "../src/KeelFactory.sol";
import {KeelToken} from "../src/KeelToken.sol";
import {KeelConstants as C} from "../src/libraries/KeelConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract KeelVaultTest is KeelTestBase {
    event Reimbursed(
        address indexed token, bytes32 indexed jobRef, address indexed creator, bytes32 commit, uint256 amount
    );
    event RunVerified(address indexed token, bytes32 indexed jobRef, bytes32 indexed commit, uint256 amount);
    event Claimed(address indexed token, address indexed holder, uint256 amount);

    function testReimbursePaysCreatorAndEmitsBothEvents() public {
        _deposit(2 ether);
        uint256 verifierBefore = imd.balanceOf(verifier);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Reimbursed(token, bytes32(uint256(1)), creator, COMMIT, 0.5 ether);
        vm.expectEmit(true, true, true, true, address(vault));
        emit RunVerified(token, bytes32(uint256(1)), COMMIT, 0.5 ether);
        vm.prank(verifier);
        vault.reimburse(token, bytes32(uint256(1)), COMMIT, 0.5 ether);
        assertEq(imd.balanceOf(creator), 0.5 ether);
        assertEq(imd.balanceOf(verifier), verifierBefore);
        assertEq(vault.project(token).basket, 1.5 ether);
        assertTrue(vault.jobUsed(bytes32(uint256(1))));
        _solvent();
    }

    function testRunRestrictionsAndAmountCap() public {
        _deposit(1 ether);
        vm.expectRevert(KeelVault.Unauthorized.selector);
        vault.reimburse(token, bytes32(uint256(1)), COMMIT, 0.5 ether);
        vm.startPrank(verifier);
        vm.expectRevert(KeelVault.InvalidAmount.selector);
        vault.reimburse(token, bytes32(uint256(1)), COMMIT, 0.5 ether + 1);
        vm.expectRevert(KeelVault.InvalidAmount.selector);
        vault.reimburse(token, bytes32(uint256(1)), COMMIT, 0);
        vm.expectRevert(KeelVault.InvalidRun.selector);
        vault.reimburse(token, bytes32(uint256(1)), bytes32(0), 1);
        vm.expectRevert(KeelVault.InvalidRun.selector);
        vault.reimburse(token, bytes32(0), COMMIT, 1);
        vm.expectRevert(KeelVault.ReimbursementAvailable.selector);
        vault.recordRun(token, bytes32(uint256(1)), COMMIT);
        vault.reimburse(token, bytes32(uint256(1)), COMMIT, 0.5 ether);
        vm.expectRevert(KeelVault.ReimbursementAvailable.selector);
        vault.recordRun(token, bytes32(uint256(2)), COMMIT);
        vault.reimburse(token, bytes32(uint256(2)), COMMIT, 0.5 ether);
        vm.expectEmit(true, true, true, true, address(vault));
        emit RunVerified(token, bytes32(uint256(3)), COMMIT, 0);
        vault.recordRun(token, bytes32(uint256(3)), COMMIT);
        vm.expectRevert(KeelVault.InsufficientBasket.selector);
        vault.reimburse(token, bytes32(uint256(4)), COMMIT, 1);
        vm.stopPrank();
        assertEq(vault.project(token).basket, 0);
    }

    function testPartialReimbursementBelowRunPriceAndRecordThreshold() public {
        _deposit(0.3 ether);
        vm.prank(verifier);
        vault.recordRun(token, bytes32(uint256(1)), COMMIT);
        vm.prank(verifier);
        vault.reimburse(token, bytes32(uint256(2)), COMMIT, 0.3 ether);
        assertEq(imd.balanceOf(creator), 0.3 ether);
        assertEq(vault.totalOwed(), 0);
    }

    function testInactiveStopsReimburseButAllowsRecordWithFundedBasket() public {
        _deposit(1 ether);
        vault.setCreatorActive(token, false);
        vm.startPrank(verifier);
        vm.expectRevert(KeelVault.InactiveCreator.selector);
        vault.reimburse(token, bytes32(uint256(1)), COMMIT, 0.5 ether);
        vault.recordRun(token, bytes32(uint256(1)), COMMIT);
        vm.stopPrank();
        assertEq(vault.project(token).basket, 1 ether);
        assertEq(imd.balanceOf(creator), 0);
        vault.setCreatorActive(token, true);
        vm.prank(verifier);
        vm.expectRevert(KeelVault.ReimbursementAvailable.selector);
        vault.recordRun(token, bytes32(uint256(2)), COMMIT);
    }

    function testSharedJobRefAcrossTokensAndRunMethods() public {
        address other = _launch(bob, JOB2, 0, -100000);
        _deposit(1 ether);
        vm.startPrank(verifier);
        vault.reimburse(token, bytes32(uint256(1)), COMMIT, 0.5 ether);
        vm.expectRevert(KeelVault.JobAlreadyUsed.selector);
        vault.recordRun(other, bytes32(uint256(1)), COMMIT);
        vault.recordRun(other, bytes32(uint256(2)), COMMIT);
        vm.expectRevert(KeelVault.JobAlreadyUsed.selector);
        vault.reimburse(token, bytes32(uint256(2)), COMMIT, 0.5 ether);
        vm.expectRevert(KeelVault.JobAlreadyUsed.selector);
        vault.reimburse(token, bytes32(uint256(1)), COMMIT, 0.5 ether);
        vm.stopPrank();
    }

    function testRunPriceBoundsAndVerifierRevocation() public {
        assertEq(vault.runPrice(), 0.5 ether);
        vault.setRunPrice(0.1 ether);
        assertEq(vault.runPrice(), 0.1 ether);
        vault.setRunPrice(2 ether);
        assertEq(vault.runPrice(), 2 ether);
        vm.expectRevert(KeelVault.InvalidRunPrice.selector);
        vault.setRunPrice(0.1 ether - 1);
        vm.expectRevert(KeelVault.InvalidRunPrice.selector);
        vault.setRunPrice(2 ether + 1);
        vm.expectRevert(KeelVault.InvalidAddress.selector);
        vault.setVerifier(address(0));
        vault.revokeVerifier();
        vm.prank(verifier);
        vm.expectRevert(KeelVault.NotConfigured.selector);
        vault.recordRun(token, bytes32(uint256(1)), COMMIT);
        vault.setVerifier(bob);
        vm.prank(verifier);
        vm.expectRevert(KeelVault.Unauthorized.selector);
        vault.recordRun(token, bytes32(uint256(1)), COMMIT);
        vm.prank(bob);
        vault.recordRun(token, bytes32(uint256(1)), COMMIT);
    }

    function testCloseRequiresBothTimingThresholdsAndCancellationRestartsNotice() public {
        uint256 launchTime = vault.project(token).launchedAt;
        vm.expectRevert(KeelVault.CloseNotReady.selector);
        vault.close(token);
        vault.announceClose(token);
        vm.expectRevert(KeelVault.NoticeExists.selector);
        vault.announceClose(token);
        vm.warp(launchTime + 7 days);
        vm.expectRevert(KeelVault.CloseNotReady.selector);
        vault.close(token);
        vault.cancelClose(token);
        vm.expectRevert(KeelVault.NoNotice.selector);
        vault.cancelClose(token);
        vm.warp(launchTime + 30 days);
        vault.announceClose(token);
        vm.warp(launchTime + 37 days - 1);
        vm.roll(block.number + 1);
        vm.expectRevert(KeelVault.CloseNotReady.selector);
        vault.close(token);
        vm.warp(launchTime + 37 days);
        vault.close(token);
        assertEq(uint256(vault.project(token).phase), uint256(KeelVault.Phase.Closed));
    }

    function testCloseAtExactThirtyDaysWithMatureNotice() public {
        vault.announceClose(token);
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);
        vault.close(token);
        assertEq(vault.project(token).snapshotBlock, block.number - 1);
    }

    function testSnapshotExcludesTransferAndPurchaseInCloseBlock() public {
        uint256 bought = _buy(alice, 100 ether);
        _deposit(2 ether);
        vault.announceClose(token);
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);
        vm.prank(alice);
        IERC20(token).transfer(bob, bought);
        _buy(bob, 50 ether);
        vault.close(token);
        KeelVault.Project memory p = vault.project(token);
        assertEq(p.circulating, bought);
        assertEq(vault.claimable(token, alice), p.poolAtClose);
        assertEq(vault.claimable(token, bob), 0);
        uint256 balanceBefore = imd.balanceOf(alice);
        vm.expectEmit(true, true, false, true, address(vault));
        emit Claimed(token, alice, p.poolAtClose);
        vm.prank(alice);
        vault.claim(token);
        assertEq(imd.balanceOf(alice), balanceBefore + p.poolAtClose);
        vm.prank(alice);
        vm.expectRevert(KeelVault.NothingToClaim.selector);
        vault.claim(token);
        vm.prank(bob);
        vm.expectRevert(KeelVault.NothingToClaim.selector);
        vault.claim(token);
        assertEq(vault.project(token).basket, 0);
        _solvent();
    }

    function testZeroCirculatingAndExcludedAddressesCannotClaim() public {
        _deposit(1 ether);
        _matureClose();
        assertEq(vault.project(token).circulating, 0);
        assertEq(vault.claimable(token, C.POOL_MANAGER), 0);
        assertEq(vault.claimable(token, C.DEAD), 0);
        vm.prank(alice);
        vm.expectRevert(KeelVault.NothingToClaim.selector);
        vault.claim(token);
        assertEq(vault.project(token).basket, 1 ether);
        _solvent();
    }

    function testDeadBalanceExcludedAndClaimsRoundDown() public {
        uint256 bought = _buy(alice, 100 ether);
        vm.startPrank(alice);
        IERC20(token).transfer(C.DEAD, bought / 3);
        IERC20(token).transfer(bob, bought / 3);
        vm.stopPrank();
        _deposit(123456789);
        _matureClose();
        KeelVault.Project memory p = vault.project(token);
        assertEq(p.circulating, bought - bought / 3);
        uint256 a = vault.claimable(token, alice);
        uint256 b = vault.claimable(token, bob);
        assertLe(a + b, p.poolAtClose);
        assertLe(p.poolAtClose - a - b, 1);
        vm.prank(alice);
        vault.claim(token);
        vm.prank(bob);
        vault.claim(token);
        assertEq(vault.project(token).totalClaimed, a + b);
        _solvent();
    }

    function testOneBuildingTokenUntilCloseThenRelaunch() public {
        vm.expectRevert(KeelFactory.CreatorHasBuildingToken.selector);
        vm.prank(creator);
        factory.launch("n", "s", JOB2, PROJECT, 3000, -100000, block.timestamp, "", META);
        _matureClose();
        assertEq(vault.buildingToken(creator), address(0));
        address next = _launch(creator, JOB2, 0, -100000);
        assertEq(vault.buildingToken(creator), next);
        assertTrue(next != token);
    }

    function testBuildingOnlyActionsAndUnauthorizedClaims() public {
        _deposit(1 ether);
        _matureClose();
        vm.expectRevert(KeelVault.NotBuilding.selector);
        vault.deposit(token, 1);
        vm.prank(verifier);
        vm.expectRevert(KeelVault.NotBuilding.selector);
        vault.reimburse(token, bytes32(uint256(1)), COMMIT, 1);
        vm.prank(verifier);
        vm.expectRevert(KeelVault.NotBuilding.selector);
        vault.recordRun(token, bytes32(uint256(1)), COMMIT);
        vm.expectRevert(KeelVault.NotBuilding.selector);
        vault.setCreatorActive(token, true);
        vm.prank(creator);
        vm.expectRevert(KeelVault.NotBuilding.selector);
        vault.lowerCreatorShare(token, 0);
        vm.prank(alice);
        vm.expectRevert(KeelVault.Unauthorized.selector);
        vault.claimCreator(token);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.claimTeam();
    }

    function testIMDFailureRollsBackAccountingAndJobConsumption() public {
        _deposit(1 ether);
        imd.setFailTransfers(true);
        vm.prank(verifier);
        vm.expectRevert("IMD transfer failed");
        vault.reimburse(token, bytes32(uint256(1)), COMMIT, 0.5 ether);
        assertFalse(vault.jobUsed(bytes32(uint256(1))));
        assertEq(vault.project(token).basket, 1 ether);
        assertEq(vault.totalOwed(), 1 ether);
        imd.setFailTransfers(false);
        imd.setTax(100);
        vm.expectRevert(KeelVault.Insolvent.selector);
        vault.deposit(token, 1 ether);
        assertEq(vault.totalOwed(), 1 ether);
    }

    function testReentrancyOnPayoutCannotWithdrawBasket() public {
        _deposit(1 ether);
        imd.setCallback(address(vault), abi.encodeCall(vault.deposit, (token, 1)));
        vm.prank(verifier);
        vault.reimburse(token, bytes32(uint256(1)), COMMIT, 0.5 ether);
        assertFalse(imd.callbackSucceeded());
        assertEq(vault.project(token).basket, 0.5 ether);
        _solvent();
    }

    function testFuzzClaimsNeverExceedPool(uint96 funding, uint16 split) public {
        uint256 amount = bound(funding, 1, 1e24);
        uint256 bought = _buy(alice, 100 ether);
        uint256 moved = bought * bound(split, 1, 9999) / 10000;
        vm.prank(alice);
        IERC20(token).transfer(bob, moved);
        _deposit(amount);
        _matureClose();
        uint256 pool = vault.project(token).poolAtClose;
        vm.prank(alice);
        uint256 a = vault.claim(token);
        vm.prank(bob);
        uint256 b = vault.claim(token);
        assertLe(a + b, pool);
        assertLe(pool - a - b, 1);
        _solvent();
    }
}
