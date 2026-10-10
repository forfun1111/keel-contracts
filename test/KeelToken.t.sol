// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {KeelToken} from "../src/KeelToken.sol";

contract KeelTokenTest is Test {
    KeelToken internal template;
    KeelToken internal token;
    address internal alice;
    address internal bob;

    function setUp() public {
        vm.roll(100);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        template = new KeelToken();
        token = KeelToken(Clones.clone(address(template)));
        token.initialize("Keel project", "KEEL", alice);
    }

    function testTemplateLockedCloneInitializesOnceAndFixedSupply() public {
        assertEq(address(token).code.length, 45);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(alice), 1e27);
        assertEq(token.name(), "Keel project");
        assertEq(token.symbol(), "KEEL");
        assertEq(token.decimals(), 18);
        vm.expectRevert(KeelToken.AlreadyInitialized.selector);
        token.initialize("x", "x", bob);
        vm.expectRevert(KeelToken.AlreadyInitialized.selector);
        template.initialize("x", "x", bob);
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", bob, 1));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1e27);
    }

    function testInvalidInitializationDoesNotConsumeClone() public {
        KeelToken clone = KeelToken(Clones.clone(address(template)));
        vm.expectRevert(KeelToken.InvalidInitialization.selector);
        clone.initialize("n", "s", address(0));
        vm.expectRevert(KeelToken.InvalidInitialization.selector);
        clone.initialize("", "s", alice);
        clone.initialize("n", "s", alice);
        assertEq(clone.balanceOf(alice), 1e27);
    }

    function testCheckpointsCollapseWithinBlockAndExcludeCurrentBlock() public {
        vm.expectRevert(KeelToken.FutureLookup.selector);
        token.balanceAt(alice, block.number);
        assertEq(token.balanceAt(alice, 99), 0);
        vm.roll(101);
        vm.startPrank(alice);
        token.transfer(bob, 100);
        token.transfer(bob, 150);
        token.transfer(alice, 1000);
        token.transfer(bob, 0);
        vm.stopPrank();
        assertEq(token.balanceAt(alice, 100), 1e27);
        assertEq(token.balanceAt(bob, 100), 0);
        vm.roll(102);
        assertEq(token.balanceAt(alice, 101), 1e27 - 250);
        assertEq(token.balanceAt(bob, 101), 250);
        vm.prank(bob);
        token.transfer(alice, 50);
        vm.roll(103);
        assertEq(token.balanceAt(bob, 102), 200);
        assertEq(token.balanceAt(bob, 101), 250);
    }

    function testFuzzPlainTransferFromAndPastBalances(uint96 input) public {
        uint256 amount = bound(input, 0, 1e27);
        vm.prank(alice);
        token.approve(bob, amount);
        vm.roll(101);
        vm.prank(bob);
        token.transferFrom(alice, bob, amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.allowance(alice, bob), 0);
        vm.roll(102);
        assertEq(token.balanceAt(bob, 101), amount);
        assertEq(token.balanceAt(alice, 101), 1e27 - amount);
        assertEq(token.balanceAt(alice, 100), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }
}
