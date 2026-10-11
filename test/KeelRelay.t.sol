// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelTestBase} from "./helpers/KeelTestBase.sol";
import {KeelVault} from "../src/KeelVault.sol";
import {KeelRelay} from "../src/KeelRelay.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract KeelRelayTest is KeelTestBase {
    uint256 internal constant VOUCHER_KEY = uint256(keccak256("Keel test voucher signer only"));
    bytes32 internal constant RUN1 = bytes32(uint256(1));
    bytes32 internal constant RUN2 = bytes32(uint256(2));
    KeelRelay internal relay;

    event RunVerified(address indexed token, bytes32 indexed jobRef, bytes32 indexed commit, uint256 amount);

    function setUp() public override {
        super.setUp();
        relay = new KeelRelay(address(this), address(vault), address(hook), vm.addr(VOUCHER_KEY));
        vault.setVerifier(address(relay));
    }

    function _voucher(uint256 key, bytes32 jobRef, uint256 amount) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, relay.runDigest(token, jobRef, COMMIT, amount));
        return abi.encodePacked(r, s, v);
    }

    function _submit(address who, bytes32 jobRef, uint256 amount) internal {
        bytes memory sig = _voucher(VOUCHER_KEY, jobRef, amount);
        vm.prank(who);
        relay.submit(token, jobRef, COMMIT, amount, sig);
    }

    function testCreatorSubmitsAndPendingFeesFundTheReimbursement() public {
        // 100 IMD bought: 1 IMD fee waits in the hook; at a 30% creator share the basket gets 0.6.
        _buy(alice, 100 ether);
        assertEq(vault.project(token).basket, 0);
        assertGt(hook.pending(token), 0);
        vm.expectEmit(true, true, true, true, address(vault));
        emit RunVerified(token, RUN1, COMMIT, 0.5 ether);
        _submit(creator, RUN1, 0.5 ether);
        assertEq(hook.pending(token), 0);
        assertEq(imd.balanceOf(creator), 0.5 ether);
        assertTrue(vault.jobUsed(RUN1));
        _solvent();
    }

    function testAnyoneMaySubmitButOnlyTheCreatorIsPaidAndOnlyOnce() public {
        _deposit(2 ether);
        uint256 bobBefore = imd.balanceOf(bob);
        _submit(bob, RUN1, 0.5 ether);
        assertEq(imd.balanceOf(creator), 0.5 ether);
        assertEq(imd.balanceOf(bob), bobBefore);
        bytes memory sig = _voucher(VOUCHER_KEY, RUN1, 0.5 ether);
        vm.expectRevert(KeelVault.JobAlreadyUsed.selector);
        relay.submit(token, RUN1, COMMIT, 0.5 ether, sig);
    }

    function testVoucherBindsEveryField() public {
        _deposit(2 ether);
        bytes memory sig = _voucher(VOUCHER_KEY, RUN1, 0.4 ether);
        vm.expectRevert(KeelRelay.InvalidSignature.selector);
        relay.submit(token, RUN1, COMMIT, 0.5 ether, sig);
        vm.expectRevert(KeelRelay.InvalidSignature.selector);
        relay.submit(token, RUN2, COMMIT, 0.4 ether, sig);
        vm.expectRevert(KeelRelay.InvalidSignature.selector);
        relay.submit(token, RUN1, keccak256("other"), 0.4 ether, sig);
        bytes memory wrongKey = _voucher(SIGNER_KEY, RUN1, 0.4 ether);
        vm.expectRevert(KeelRelay.InvalidSignature.selector);
        relay.submit(token, RUN1, COMMIT, 0.4 ether, wrongKey);
        relay.submit(token, RUN1, COMMIT, 0.4 ether, sig);
        assertEq(imd.balanceOf(creator), 0.4 ether);
    }

    function testVaultRulesStillApply() public {
        // Over the run price.
        _deposit(2 ether);
        bytes memory sig = _voucher(VOUCHER_KEY, RUN1, 0.6 ether);
        vm.expectRevert(KeelVault.InvalidAmount.selector);
        relay.submit(token, RUN1, COMMIT, 0.6 ether, sig);
        // A record voucher while the basket can pay.
        sig = _voucher(VOUCHER_KEY, RUN1, 0);
        vm.expectRevert(KeelVault.ReimbursementAvailable.selector);
        relay.submit(token, RUN1, COMMIT, 0, sig);
        // Inactive creator: no payout, recording works.
        vault.setCreatorActive(token, false);
        bytes memory pay = _voucher(VOUCHER_KEY, RUN1, 0.5 ether);
        vm.expectRevert(KeelVault.InactiveCreator.selector);
        relay.submit(token, RUN1, COMMIT, 0.5 ether, pay);
        relay.submit(token, RUN1, COMMIT, 0, sig);
        assertTrue(vault.jobUsed(RUN1));
    }

    function testShortBasketWaitsThenPaysOrRecords() public {
        bytes memory pay = _voucher(VOUCHER_KEY, RUN1, 0.5 ether);
        vm.expectRevert(KeelVault.InsufficientBasket.selector);
        relay.submit(token, RUN1, COMMIT, 0.5 ether, pay);
        // The record voucher for another run works while the basket is short.
        _submit(creator, RUN2, 0);
        assertEq(imd.balanceOf(creator), 0);
        // Trading fills the basket; the same payout voucher now goes through.
        _buy(alice, 100 ether);
        relay.submit(token, RUN1, COMMIT, 0.5 ether, pay);
        assertEq(imd.balanceOf(creator), 0.5 ether);
        _solvent();
    }

    function testStrangerCannotCancelAPayoutWithTheRecordVoucher() public {
        // The basket is empty, so the payout waits; the published record voucher must not burn the run.
        bytes memory record = _voucher(VOUCHER_KEY, RUN1, 0);
        vm.prank(bob);
        vm.expectRevert(KeelRelay.RecordNotAllowed.selector);
        relay.submit(token, RUN1, COMMIT, 0, record);
        assertFalse(vault.jobUsed(RUN1));
        // Trading fills the basket and the creator's payout voucher still pays.
        _buy(alice, 100 ether);
        _submit(bob, RUN1, 0.5 ether);
        assertEq(imd.balanceOf(creator), 0.5 ether);
        _solvent();
    }

    function testCreatorAndOwnerMayRecordWhileTheBasketIsShort() public {
        _submit(creator, RUN1, 0);
        assertTrue(vault.jobUsed(RUN1));
        relay.submit(token, RUN2, COMMIT, 0, _voucher(VOUCHER_KEY, RUN2, 0));
        assertTrue(vault.jobUsed(RUN2));
        assertEq(imd.balanceOf(creator), 0);
    }

    function testRecordCountsPendingFeesBeforeDecidingTheBasketCannotPay() public {
        // 100 IMD bought: the 1 IMD fee waits in the hook and would put 0.6 IMD in the basket.
        _buy(alice, 100 ether);
        assertEq(vault.project(token).basket, 0);
        bytes memory record = _voucher(VOUCHER_KEY, RUN1, 0);
        vm.prank(creator);
        vm.expectRevert(KeelVault.ReimbursementAvailable.selector);
        relay.submit(token, RUN1, COMMIT, 0, record);
        assertFalse(vault.jobUsed(RUN1));
        _submit(creator, RUN1, 0.5 ether);
        assertEq(imd.balanceOf(creator), 0.5 ether);
    }

    function testRecordVoucherForAnUnknownTokenIsRefused() public {
        bytes32 digest = relay.runDigest(alice, RUN1, COMMIT, 0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(VOUCHER_KEY, digest);
        vm.prank(bob);
        vm.expectRevert(KeelRelay.RecordNotAllowed.selector);
        relay.submit(alice, RUN1, COMMIT, 0, abi.encodePacked(r, s, v));
    }

    function testOnlyOwnerRotatesOrRevokesTheSigner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        relay.setSigner(alice);
        vm.expectRevert(KeelRelay.InvalidAddress.selector);
        relay.setSigner(address(0));
        _deposit(2 ether);
        bytes memory sig = _voucher(VOUCHER_KEY, RUN1, 0.5 ether);
        relay.revokeSigner();
        vm.expectRevert(KeelRelay.InvalidSignature.selector);
        relay.submit(token, RUN1, COMMIT, 0.5 ether, sig);
        relay.setSigner(vm.addr(VOUCHER_KEY));
        relay.submit(token, RUN1, COMMIT, 0.5 ether, sig);
    }

    function testConstructorRejectsZeroAddresses() public {
        vm.expectRevert(KeelRelay.InvalidAddress.selector);
        new KeelRelay(address(this), address(0), address(hook), alice);
        vm.expectRevert(KeelRelay.InvalidAddress.selector);
        new KeelRelay(address(this), address(vault), address(0), alice);
        vm.expectRevert(KeelRelay.InvalidAddress.selector);
        new KeelRelay(address(this), address(vault), address(hook), address(0));
    }
}
