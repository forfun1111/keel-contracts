// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {KeelTestBase} from "./helpers/KeelTestBase.sol";
import {KeelFactory} from "../src/KeelFactory.sol";
import {KeelVault} from "../src/KeelVault.sol";
import {KeelToken} from "../src/KeelToken.sol";
import {KeelRouter} from "../src/KeelRouter.sol";
import {KeelConstants as C} from "../src/libraries/KeelConstants.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";
import {Metadata} from "../src/libraries/Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

contract ContractSigner is IERC1271 {
    bytes32 public immutable accepted;

    constructor(bytes32 digest) {
        accepted = digest;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        return hash == accepted && keccak256(signature) == keccak256("approval")
            ? IERC1271.isValidSignature.selector
            : bytes4(0);
    }
}

contract KeelFactoryTest is KeelTestBase {
    function testPermitRejectsChangedCreatorAndSignedFields() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signature(bob, "Keel Project", "KEEL", JOB2, PROJECT, -100000, deadline);
        vm.expectRevert(KeelFactory.InvalidSignature.selector);
        vm.prank(alice);
        factory.launch("Keel Project", "KEEL", JOB2, PROJECT, 0, -100000, deadline, sig, META);
        vm.startPrank(bob);
        vm.expectRevert(KeelFactory.InvalidSignature.selector);
        factory.launch("Wrong name", "KEEL", JOB2, PROJECT, 0, -100000, deadline, sig, META);
        vm.expectRevert(KeelFactory.InvalidSignature.selector);
        factory.launch("Keel Project", "WRONG", JOB2, PROJECT, 0, -100000, deadline, sig, META);
        vm.expectRevert(KeelFactory.InvalidSignature.selector);
        factory.launch("Keel Project", "KEEL", PROJECT, PROJECT, 0, -100000, deadline, sig, META);
        vm.expectRevert(KeelFactory.InvalidSignature.selector);
        factory.launch("Keel Project", "KEEL", JOB2, JOB, 0, -100000, deadline, sig, META);
        vm.expectRevert(KeelFactory.InvalidSignature.selector);
        factory.launch("Keel Project", "KEEL", JOB2, PROJECT, 0, -99999, deadline, sig, META);
        vm.expectRevert(KeelFactory.InvalidSignature.selector);
        factory.launch("Keel Project", "KEEL", JOB2, PROJECT, 0, -100000, deadline + 1, sig, META);
        vm.expectRevert(KeelFactory.InvalidSignature.selector);
        factory.launch("Keel Project", "KEEL", JOB2, PROJECT, 0, -100000, deadline, hex"112233", META);
        vm.stopPrank();
    }

    function testPermitReplayRejectedAcrossChainAndFactory() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signature(bob, "Keel Project", "KEEL", JOB2, PROJECT, -100000, deadline);
        uint256 originalChain = block.chainid;
        vm.chainId(originalChain + 1);
        vm.prank(bob);
        vm.expectRevert(KeelFactory.InvalidSignature.selector);
        factory.launch("Keel Project", "KEEL", JOB2, PROJECT, 0, -100000, deadline, sig, META);
        vm.chainId(originalChain);
        KeelVault nextVault = new KeelVault(address(this));
        KeelFactory nextFactory =
            new KeelFactory(address(this), address(nextVault), address(implementation), 0);
        nextVault.wire(address(nextFactory));
        nextFactory.setSigner(signer);
        nextFactory.setStartTickBounds(-200000, 200000);
        nextFactory.setPaused(false);
        vm.prank(bob);
        vm.expectRevert(KeelFactory.InvalidSignature.selector);
        nextFactory.launch("Keel Project", "KEEL", JOB2, PROJECT, 0, -100000, deadline, sig, META);
    }

    function testUniqueJobEvenWithDifferentCreatorAndNewPermit() public {
        vm.expectRevert(KeelFactory.JobAlreadyLaunched.selector);
        vm.prank(bob);
        factory.launch("n", "s", JOB, PROJECT, 1000, -100000, block.timestamp, "", META);
        _matureClose();
        vm.expectRevert(KeelFactory.JobAlreadyLaunched.selector);
        vm.prank(creator);
        factory.launch("n", "s", JOB, PROJECT, 1000, -100000, block.timestamp, "", META);
    }

    function testFactoryStartsPausedAndSettingsRequired() public {
        KeelVault v = new KeelVault(address(this));
        KeelFactory f = new KeelFactory(address(this), address(v), address(implementation), 0);
        assertTrue(f.paused());
        vm.expectRevert(KeelFactory.Paused.selector);
        f.launch("n", "s", JOB2, PROJECT, 0, -100000, block.timestamp, "", META);
        f.setPaused(false);
        vm.expectRevert(KeelFactory.NotConfigured.selector);
        f.launch("n", "s", JOB2, PROJECT, 0, -100000, block.timestamp, "", META);
        f.setSigner(signer);
        vm.expectRevert(KeelFactory.NotConfigured.selector);
        f.launch("n", "s", JOB2, PROJECT, 0, -100000, block.timestamp, "", META);
        f.setStartTickBounds(-200000, 0);
        vm.expectRevert(KeelFactory.NotConfigured.selector);
        f.launch("n", "s", JOB2, PROJECT, 0, -100000, block.timestamp, "", META);
        v.wire(address(f));
        vm.expectRevert(KeelFactory.InvalidSignature.selector);
        f.launch("n", "s", JOB2, PROJECT, 0, -100000, block.timestamp, "", META);
        f.revokeSigner();
        vm.expectRevert(KeelFactory.NotConfigured.selector);
        f.launch("n", "s", JOB2, PROJECT, 0, -100000, block.timestamp, "", META);
    }

    function testOwnerControlsAndTwoStepTransferForAllThreeContracts() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        factory.setSigner(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setVerifier(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        router.setEthPool(10000, 200);
        vm.stopPrank();
        factory.transferOwnership(alice);
        vault.transferOwnership(alice);
        router.transferOwnership(alice);
        assertEq(factory.owner(), address(this));
        assertEq(vault.owner(), address(this));
        assertEq(router.owner(), address(this));
        vm.prank(bob);
        vm.expectRevert();
        factory.acceptOwnership();
        vm.startPrank(alice);
        factory.acceptOwnership();
        vault.acceptOwnership();
        router.acceptOwnership();
        vm.stopPrank();
        assertEq(factory.owner(), alice);
        assertEq(vault.owner(), alice);
        assertEq(router.owner(), alice);
    }

    function testSignerCanBe1271ContractAndCreatorChoosesUnsignedShare() public {
        uint256 deadline = block.timestamp;
        bytes32 digest = factory.launchDigest(
            bob,
            keccak256(bytes(JOB2)),
            keccak256(bytes(PROJECT)),
            keccak256("n"),
            keccak256("s"),
            -100000,
            deadline
        );
        factory.setSigner(address(new ContractSigner(digest)));
        vm.prank(bob);
        address launched = factory.launch("n", "s", JOB2, PROJECT, 8000, -100000, deadline, "approval", META);
        assertEq(vault.project(launched).creatorBps, 8000);
    }

    function testLaunchValidationExpiryUUIDBoundsAndMetadata() public {
        vm.expectRevert(KeelFactory.Expired.selector);
        factory.launch("n", "s", JOB2, PROJECT, 0, -100000, block.timestamp - 1, "", META);
        vm.expectRevert(KeelFactory.InvalidUUID.selector);
        factory.launch("n", "s", "job", PROJECT, 0, -100000, block.timestamp, "", META);
        vm.expectRevert(KeelFactory.InvalidUUID.selector);
        factory.launch(
            "n", "s", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", PROJECT, 0, -100000, block.timestamp, "", META
        );
        vm.expectRevert(KeelFactory.InvalidUUID.selector);
        factory.launch(
            "n", "s", JOB2, "12345678x1234-1234-1234-123456789abc", 0, -100000, block.timestamp, "", META
        );
        vm.expectRevert(KeelFactory.InvalidName.selector);
        factory.launch("", "s", JOB2, PROJECT, 0, -100000, block.timestamp, "", META);
        vm.expectRevert(KeelFactory.InvalidShare.selector);
        factory.launch("n", "s", JOB2, PROJECT, 8001, -100000, block.timestamp, "", META);
        vm.expectRevert(KeelFactory.InvalidTick.selector);
        factory.launch("n", "s", JOB2, PROJECT, 0, -200001, block.timestamp, "", META);
        vm.expectRevert(Metadata.InvalidMetadata.selector);
        factory.launch(
            "n", "s", JOB2, PROJECT, 0, -100000, block.timestamp, "", '{"description":"x","image":"x"}'
        );
        vm.expectRevert(KeelFactory.InvalidTick.selector);
        factory.setStartTickBounds(1, 0);
        vm.expectRevert(KeelFactory.InvalidTick.selector);
        factory.setStartTickBounds(-887201, 0);
        vm.expectRevert(KeelFactory.InvalidTick.selector);
        factory.setStartTickBounds(0, 887000);
        vm.expectRevert(KeelFactory.InvalidAddress.selector);
        factory.setSigner(address(0));
    }

    function testNonAlignedNegativeStartTickRoundsStrictlyUp() public {
        address launched = _launch(bob, JOB2, 0, -100001);
        assertEq(factory.lowerTick(launched), -100000);
    }

    function testConstructorDeploymentGasAndRuntimeSizes() public {
        // Raw CREATE keeps this gas measurement correct even with Foundry dynamic test linking,
        // which otherwise rewrites new Contract(...) into a gas-free vm.deployCode cheatcode.
        bytes memory initCode = abi.encodePacked(
            vm.getCode("KeelFactory.sol:KeelFactory"),
            abi.encode(address(this), address(vault), address(implementation), uint256(0))
        );
        uint256 beforeGas = gasleft();
        address deployed = address(0);
        assembly ("memory-safe") { deployed := create(0, add(initCode, 32), mload(initCode)) }
        uint256 consumed = beforeGas - gasleft();
        assertTrue(deployed != address(0));
        KeelFactory f = KeelFactory(deployed);
        emit log_named_uint("Factory constructor gas (including mining + hook deployment)", consumed);
        emit log_named_uint("Hook salt candidates", f.hookSaltAttempts());
        assertLt(consumed, 16777216);
        assertLe(address(f).code.length, 24576);
        assertLe(f.hook().code.length, 24576);
        assertLe(address(vault).code.length, 24576);
        assertLe(address(router).code.length, 24576);
        assertLe(type(KeelFactory).creationCode.length + 128, 49152);
    }
}

contract HookMinerTest is KeelTestBase {
    function testFuzzMinerAddressAndMeasuredGas(bytes32 initHash, uint32 start) public view {
        uint256 beforeGas = gasleft();
        (bytes32 salt, address predicted, uint256 attempts) =
            HookMiner.find(address(factory), initHash, start);
        uint256 consumed = beforeGas - gasleft();
        assertEq(
            predicted,
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, initHash))))
            )
        );
        assertEq(uint160(predicted) & 0x3fff, 0x28cc);
        assertEq(uint256(salt), uint256(start) + attempts - 1);
        // The memory buffer is reused: no growing allocation and no code checks in the hash loop.
        assertLt(consumed, attempts * 200 + 2000);
    }

    function testLogMinerGas() public {
        uint256 beforeGas = gasleft();
        (bytes32 salt, address predicted, uint256 attempts) =
            HookMiner.find(address(factory), keccak256("measurement"), 0);
        uint256 consumed = beforeGas - gasleft();
        emit log_named_uint("Salt search gas", consumed);
        emit log_named_uint("Salt candidates", attempts);
        emit log_named_uint("Gas per candidate", consumed / attempts);
        assertEq(uint160(predicted) & 0x3fff, 0x28cc);
        assertEq(uint256(salt) + 1, attempts);
    }
}
