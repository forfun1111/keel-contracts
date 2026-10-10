// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {KeelTestBase} from "./helpers/KeelTestBase.sol";
import {KeelToken} from "../src/KeelToken.sol";
import {KeelVault} from "../src/KeelVault.sol";
import {KeelFactory} from "../src/KeelFactory.sol";
import {KeelRouter} from "../src/KeelRouter.sol";
import {KeelConstants as C} from "../src/libraries/KeelConstants.sol";

contract KeelSetupTest is KeelTestBase {
    function testRegistrationUnavailableUntilWireAndWireIsOwnerOnlyOnce() public {
        KeelVault fresh = new KeelVault(address(this));
        vm.expectRevert(KeelVault.NotConfigured.selector);
        fresh.register(token, creator, keccak256(bytes(JOB)), keccak256(bytes(PROJECT)), 1000);
        vm.prank(alice);
        vm.expectRevert();
        fresh.wire(address(factory));
        vm.expectRevert(KeelVault.InvalidAddress.selector);
        fresh.wire(address(0));
        vm.expectRevert(KeelVault.InvalidFactory.selector);
        fresh.wire(address(factory));
        vm.expectRevert(KeelVault.AlreadyWired.selector);
        vault.wire(address(factory));
        vm.expectRevert(KeelVault.Unauthorized.selector);
        vault.register(token, creator, keccak256(bytes(JOB)), keccak256(bytes(PROJECT)), 1000);
        vm.expectRevert(KeelVault.Unauthorized.selector);
        vault.accrue(token, 1);
        vm.prank(address(hook));
        vm.expectRevert(KeelVault.Insolvent.selector);
        vault.accrue(token, 1);
        assertEq(vault.totalOwed(), 0);
    }

    function testEmptyClaimsAndUnknownTokensRejected() public {
        vm.expectRevert(KeelVault.NothingToClaim.selector);
        vault.claimTeam();
        vm.prank(creator);
        vm.expectRevert(KeelVault.NothingToClaim.selector);
        vault.claimCreator(token);
        vm.expectRevert(KeelVault.InvalidAmount.selector);
        vault.deposit(token, 0);
        vm.expectRevert(KeelVault.UnknownToken.selector);
        vault.deposit(address(implementation), 1);
        vm.prank(verifier);
        vm.expectRevert(KeelVault.InvalidRun.selector);
        vault.recordRun(token, bytes32(uint256(1)), bytes32(0));
    }
}

contract EmptyChainDeploymentTest is Test {
    function testConstructorsOnlyDeployOnEmptyChain() public {
        assertEq(C.POOL_MANAGER.code.length, 0);
        assertEq(C.IMD.code.length, 0);
        KeelToken template = new KeelToken();
        KeelVault vault = new KeelVault(address(this));
        KeelFactory factory = new KeelFactory(address(this), address(vault), address(template), 0);
        KeelRouter router = new KeelRouter(address(this), address(factory));
        assertEq(vault.owner(), address(this));
        assertEq(factory.owner(), address(this));
        assertEq(router.owner(), address(this));
        assertEq(vault.factory(), address(0));
        assertTrue(factory.paused());
        assertFalse(router.ethPoolConfigured());
        assertEq(factory.vault(), address(vault));
        assertEq(uint160(factory.hook()) & 0x3fff, 0x28cc);
    }
}
