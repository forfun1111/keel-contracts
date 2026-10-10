// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KeelToken} from "../../src/KeelToken.sol";
import {KeelVault} from "../../src/KeelVault.sol";
import {KeelFactory} from "../../src/KeelFactory.sol";
import {KeelHook} from "../../src/KeelHook.sol";
import {KeelRouter} from "../../src/KeelRouter.sol";
import {KeelConstants as C} from "../../src/libraries/KeelConstants.sol";
import {MockIMD} from "./MockIMD.sol";

abstract contract KeelTestBase is Test {
    uint256 internal constant SIGNER_KEY = uint256(keccak256("Keel test signer only"));
    string internal constant JOB = "11111111-1111-4111-8111-111111111111";
    string internal constant JOB2 = "22222222-2222-4222-8222-222222222222";
    string internal constant PROJECT = "33333333-3333-4333-8333-333333333333";
    string internal constant META =
        '{"description":"Swarm project","image":"https://example.test/image.png","links":{"website":"https://example.test"}}';
    bytes32 internal constant COMMIT = keccak256("verified source commit");
    KeelToken internal implementation;
    KeelVault internal vault;
    KeelFactory internal factory;
    KeelHook internal hook;
    KeelRouter internal router;
    PoolManager internal manager;
    MockIMD internal imd;
    address internal creator;
    address internal alice;
    address internal bob;
    address internal verifier;
    address internal signer;
    address internal token;

    function setUp() public virtual {
        vm.warp(1800000000);
        vm.roll(100);
        creator = makeAddr("creator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        verifier = makeAddr("verifier");
        signer = vm.addr(SIGNER_KEY);
        // Executes the actual constructors at the fixed mainnet addresses, preserving immutables.
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), C.POOL_MANAGER);
        deployCodeTo("MockIMD.sol:MockIMD", C.IMD);
        manager = PoolManager(C.POOL_MANAGER);
        imd = MockIMD(C.IMD);
        implementation = new KeelToken();
        vault = new KeelVault(address(this));
        factory = new KeelFactory(address(this), address(vault), address(implementation), 0);
        hook = KeelHook(factory.hook());
        router = new KeelRouter(address(this), address(factory));
        vault.wire(address(factory));
        vault.setVerifier(verifier);
        factory.setSigner(signer);
        factory.setStartTickBounds(-200000, 200000);
        factory.setPaused(false);
        token = _launch(creator, JOB, 3000, -100000);
        imd.mint(alice, 1e27);
        imd.mint(bob, 1e27);
        imd.mint(address(this), 1e27);
        vm.prank(alice);
        imd.approve(address(router), type(uint256).max);
        vm.prank(bob);
        imd.approve(address(router), type(uint256).max);
        imd.approve(address(vault), type(uint256).max);
    }

    function _signature(
        address who,
        string memory name,
        string memory symbol,
        string memory job,
        string memory project,
        int24 tick,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = factory.launchDigest(
            who,
            keccak256(bytes(job)),
            keccak256(bytes(project)),
            keccak256(bytes(name)),
            keccak256(bytes(symbol)),
            tick,
            deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _launch(address who, string memory job, uint256 bps, int24 tick) internal returns (address) {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _signature(who, "Keel Project", "KEEL", job, PROJECT, tick, deadline);
        vm.prank(who);
        return factory.launch("Keel Project", "KEEL", job, PROJECT, bps, tick, deadline, signature, META);
    }

    function _buy(address who, uint256 amount) internal returns (uint256 out) {
        vm.prank(who);
        out = router.swapExactInput(C.IMD, token, amount, 1, block.timestamp, who);
    }

    function _sell(address who, uint256 amount) internal returns (uint256 out) {
        vm.startPrank(who);
        IERC20(token).approve(address(router), amount);
        out = router.swapExactInput(token, C.IMD, amount, 1, block.timestamp, who);
        vm.stopPrank();
    }

    function _deposit(uint256 amount) internal {
        vault.deposit(token, amount);
    }

    function _matureClose() internal {
        vault.announceClose(token);
        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 1);
        vault.close(token);
    }

    function _solvent() internal view {
        assertGe(imd.balanceOf(address(vault)), vault.totalOwed());
        KeelVault.Project memory p = vault.project(token);
        assertLe(p.totalClaimed, p.poolAtClose);
    }
}
