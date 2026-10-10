// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {KeelTestBase} from "./helpers/KeelTestBase.sol";
import {KeelVault} from "../src/KeelVault.sol";
import {KeelHook} from "../src/KeelHook.sol";
import {KeelRouter} from "../src/KeelRouter.sol";
import {KeelConstants as C} from "../src/libraries/KeelConstants.sol";
import {MockIMD} from "./helpers/MockIMD.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract KeelHandler is Test {
    KeelVault public vault;
    KeelHook public hook;
    KeelRouter public router;
    MockIMD public imd;
    address[2] public tokens;
    address[3] public actors;
    uint256 public nextJob = 1;
    uint256 public incoming;
    uint256 public paid;
    uint256 public reimbursements;
    uint256 public records;
    uint256 public closes;
    uint256 public claims;
    uint256[2] public lastShare;

    constructor(KeelVault v, KeelHook h, KeelRouter r, address[2] memory ts, address[3] memory as_) {
        vault = v;
        hook = h;
        router = r;
        tokens = ts;
        actors = as_;
        imd = MockIMD(C.IMD);
        lastShare[0] = v.project(ts[0]).creatorBps;
        lastShare[1] = v.project(ts[1]).creatorBps;
        imd.mint(address(this), 1e30);
        imd.approve(address(vault), type(uint256).max);
        for (uint256 i = 0; i < actors.length; ++i) {
            imd.mint(actors[i], 1e30);
            vm.prank(actors[i]);
            imd.approve(address(router), type(uint256).max);
        }
    }

    function acceptOwnership() external {
        vault.acceptOwnership();
    }

    function _before() private view returns (uint256) {
        return imd.balanceOf(address(vault));
    }

    function _after(uint256 beforeBalance) private {
        uint256 afterBalance = imd.balanceOf(address(vault));
        if (afterBalance >= beforeBalance) incoming += afterBalance - beforeBalance;
        else paid += beforeBalance - afterBalance;
    }

    function trade(uint256 which, uint256 who, uint96 rawAmount, bool sell) external {
        address token = tokens[which % 2];
        address trader = actors[who % 3];
        if (sell) {
            uint256 available = IERC20(token).balanceOf(trader) / 2;
            if (available < 1e12) return;
            uint256 amount = bound(rawAmount, 1e12, available);
            vm.startPrank(trader);
            IERC20(token).approve(address(router), amount);
            router.swapExactInput(token, C.IMD, amount, 1, block.timestamp, trader);
            vm.stopPrank();
        } else {
            uint256 amount = bound(rawAmount, 1e9, 100 ether);
            vm.prank(trader);
            router.swapExactInput(C.IMD, token, amount, 1, block.timestamp, trader);
        }
    }

    function transfer(uint256 which, uint256 who, uint256 to, uint96 rawAmount) external {
        address token = tokens[which % 2];
        address from = actors[who % 3];
        uint256 amount = bound(rawAmount, 0, IERC20(token).balanceOf(from));
        vm.prank(from);
        IERC20(token).transfer(actors[to % 3], amount);
    }

    function deposit(uint256 which, uint96 rawAmount) external {
        address token = tokens[which % 2];
        if (vault.project(token).phase != KeelVault.Phase.Building) return;
        uint256 beforeBalance = _before();
        vault.deposit(token, bound(rawAmount, 1, 3 ether));
        _after(beforeBalance);
    }

    function distribute(uint256 which) external {
        uint256 beforeBalance = _before();
        hook.distribute(tokens[which % 2]);
        _after(beforeBalance);
    }

    function lowerShare(uint256 which, uint16 rawBps) external {
        uint256 index = which % 2;
        address token = tokens[index];
        KeelVault.Project memory p = vault.project(token);
        if (p.phase != KeelVault.Phase.Building || p.creatorBps == 0) return;
        uint256 beforeBalance = _before();
        uint256 newBps = rawBps % p.creatorBps;
        vm.prank(p.creator);
        vault.lowerCreatorShare(token, newBps);
        assertLt(newBps, lastShare[index]);
        lastShare[index] = newBps;
        _after(beforeBalance);
    }

    function setActive(uint256 which, bool active) external {
        address token = tokens[which % 2];
        if (vault.project(token).phase != KeelVault.Phase.Building) return;
        uint256 beforeBalance = _before();
        vault.setCreatorActive(token, active);
        _after(beforeBalance);
    }

    function setPrice(uint96 rawPrice) external {
        vault.setRunPrice(bound(rawPrice, 0.1 ether, 2 ether));
    }

    function run(uint256 which, uint96 rawAmount) external {
        address token = tokens[which % 2];
        KeelVault.Project memory p = vault.project(token);
        if (p.phase != KeelVault.Phase.Building) return;
        uint256 beforeBalance = _before();
        bytes32 job = bytes32(nextJob++);
        bytes32 commit = keccak256(abi.encode(job, token));
        if (p.creatorActive && p.basket >= vault.runPrice()) {
            uint256 amount = bound(rawAmount, 1, vault.runPrice());
            uint256 creatorBefore = imd.balanceOf(p.creator);
            vault.reimburse(token, job, commit, amount);
            assertEq(imd.balanceOf(p.creator), creatorBefore + amount);
            ++reimbursements;
        } else {
            vault.recordRun(token, job, commit);
            ++records;
        }
        assertTrue(vault.jobUsed(job));
        _after(beforeBalance);
    }

    function advance(uint32 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 1 days, 12 days));
        vm.roll(block.number + 1);
    }

    function noticeOrClose(uint256 which, bool cancel) external {
        address token = tokens[which % 2];
        KeelVault.Project memory p = vault.project(token);
        if (p.phase != KeelVault.Phase.Building) return;
        uint256 beforeBalance = _before();
        if (p.closeNotice == 0) {
            vault.announceClose(token);
        } else if (cancel) {
            vault.cancelClose(token);
        } else if (
            block.timestamp >= uint256(p.closeNotice) + 7 days
                && block.timestamp >= uint256(p.launchedAt) + 30 days
        ) {
            vm.roll(block.number + 1);
            vault.close(token);
            ++closes;
        }
        _after(beforeBalance);
    }

    function claim(uint256 which, uint256 who) external {
        address token = tokens[which % 2];
        address holder = actors[who % 3];
        uint256 amount = vault.claimable(token, holder);
        if (amount == 0) return;
        uint256 beforeBalance = _before();
        vm.prank(holder);
        assertEq(vault.claim(token), amount);
        ++claims;
        _after(beforeBalance);
    }

    function withdrawAccrued(uint256 which) external {
        uint256 beforeBalance = _before();
        address token = tokens[which % 2];
        KeelVault.Project memory p = vault.project(token);
        if (p.creatorAccrued != 0) {
            vm.prank(p.creator);
            vault.claimCreator(token);
        }
        if (vault.teamAccrued() != 0) vault.claimTeam();
        _after(beforeBalance);
    }
}

contract KeelInvariantTest is KeelTestBase {
    KeelHandler internal handler;
    address internal second;

    function setUp() public override {
        super.setUp();
        second = _launch(bob, JOB2, 8000, -90000);
        handler = new KeelHandler(vault, hook, router, [token, second], [alice, bob, creator]);
        vault.setVerifier(address(handler));
        vault.transferOwnership(address(handler));
        handler.acceptOwnership();
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.transfer.selector;
        selectors[2] = handler.deposit.selector;
        selectors[3] = handler.distribute.selector;
        selectors[4] = handler.lowerShare.selector;
        selectors[5] = handler.setActive.selector;
        selectors[6] = handler.setPrice.selector;
        selectors[7] = handler.run.selector;
        selectors[8] = handler.advance.selector;
        selectors[9] = handler.noticeOrClose.selector;
        selectors[10] = handler.claim.selector;
        selectors[11] = handler.withdrawAccrued.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function testHandlerLifecycleExercisesPaymentsRecordsAndClosedClaims() public {
        handler.deposit(0, 1 ether);
        handler.run(0, 0.5 ether);
        handler.setActive(0, false);
        handler.run(0, 0);
        handler.trade(0, 0, 100 ether, false);
        handler.noticeOrClose(0, false);
        handler.advance(12 days);
        handler.advance(12 days);
        handler.advance(7 days);
        handler.noticeOrClose(0, false);
        handler.claim(0, 0);
        assertEq(handler.reimbursements(), 1);
        assertEq(handler.records(), 1);
        assertEq(handler.closes(), 1);
        assertEq(handler.claims(), 1);
        invariantBalanceCoversEveryLiabilityAndFundsAreConserved();
        invariantClaimsNeverExceedFrozenPoolAndSharesOnlyFall();
        invariantHookPendingFullyBackedAndRouterHoldsNothing();
        invariantTokenSupplyAndKnownHoldersConserved();
    }

    function invariantBalanceCoversEveryLiabilityAndFundsAreConserved() public view {
        KeelVault.Project memory a = vault.project(token);
        KeelVault.Project memory b = vault.project(second);
        uint256 owed = a.basket + a.creatorAccrued + b.basket + b.creatorAccrued + vault.teamAccrued();
        assertEq(owed, vault.totalOwed());
        assertEq(imd.balanceOf(address(vault)), owed);
        assertEq(handler.incoming(), handler.paid() + owed);
    }

    function invariantClaimsNeverExceedFrozenPoolAndSharesOnlyFall() public view {
        for (uint256 i = 0; i < 2; ++i) {
            address t = i == 0 ? token : second;
            KeelVault.Project memory p = vault.project(t);
            assertEq(p.creatorBps, handler.lastShare(i));
            assertLe(p.totalClaimed, p.poolAtClose);
            if (p.phase == KeelVault.Phase.Closed) {
                assertEq(p.basket, p.poolAtClose - p.totalClaimed);
                assertEq(vault.buildingToken(p.creator), address(0));
            } else {
                assertEq(vault.buildingToken(p.creator), t);
            }
        }
    }

    function invariantHookPendingFullyBackedAndRouterHoldsNothing() public view {
        assertEq(hook.pending(token) + hook.pending(second), hook.totalPending());
        assertEq(manager.balanceOf(address(hook), uint256(uint160(C.IMD))), hook.totalPending());
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(router)), 0);
        assertEq(IERC20(token).balanceOf(address(router)), 0);
        assertEq(IERC20(second).balanceOf(address(router)), 0);
    }

    function invariantTokenSupplyAndKnownHoldersConserved() public view {
        for (uint256 j = 0; j < 2; ++j) {
            IERC20 t = IERC20(j == 0 ? token : second);
            uint256 sum = t.balanceOf(C.POOL_MANAGER) + t.balanceOf(C.DEAD);
            for (uint256 i = 0; i < 3; ++i) {
                sum += t.balanceOf(handler.actors(i));
            }
            assertEq(sum, C.SUPPLY);
            assertEq(t.totalSupply(), C.SUPPLY);
        }
    }
}
