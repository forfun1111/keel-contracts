// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IKeelToken, IKeelHook, IKeelFactory} from "./interfaces/IKeel.sol";
import {KeelConstants as C} from "./libraries/KeelConstants.sol";

contract KeelVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Phase {
        Building,
        Closed
    }

    struct Project {
        address creator;
        Phase phase;
        bool creatorActive;
        uint16 creatorBps;
        uint64 launchedAt;
        uint64 closeNotice;
        uint256 basket;
        uint256 creatorAccrued;
        uint256 snapshotBlock;
        uint256 poolAtClose;
        uint256 circulating;
        uint256 totalClaimed;
        bytes32 jobHash;
        bytes32 projectHash;
    }

    IERC20 public constant imd = IERC20(C.IMD);
    uint256 public constant TEAM_BPS = 1000;
    uint256 public constant CLOSE_NOTICE = 7 days;
    uint256 public constant MIN_LIFETIME = 30 days;
    address public factory;
    address public hook;
    address public verifier;
    uint256 public runPrice = 0.5 ether;
    uint256 public teamAccrued;
    /// @notice Sum of every basket (including unclaimed closed pools), creator balance and team balance.
    uint256 public totalOwed;
    mapping(address => Project) private _projects;
    mapping(address => address) public buildingToken;
    mapping(bytes32 => bool) public jobUsed;
    mapping(address => mapping(address => bool)) public claimed;

    error Unauthorized();
    error InvalidAddress();
    error NotConfigured();
    error AlreadyWired();
    error InvalidFactory();
    error UnknownToken();
    error NotBuilding();
    error InvalidShare();
    error CreatorHasBuildingToken();
    error InactiveCreator();
    error InvalidRun();
    error JobAlreadyUsed();
    error InsufficientBasket();
    error ReimbursementAvailable();
    error InvalidAmount();
    error InvalidRunPrice();
    error CloseNotReady();
    error NoticeExists();
    error NoNotice();
    error NothingToClaim();
    error Insolvent();

    event Wired(address indexed factory, address indexed hook);
    event Registered(
        address indexed token,
        address indexed creator,
        bytes32 indexed jobHash,
        bytes32 projectHash,
        uint256 creatorBps
    );
    event FeeAccrued(address indexed token, uint256 amount, uint256 team, uint256 creator, uint256 basket);
    event Deposited(address indexed token, address indexed from, uint256 amount);
    event CreatorShareLowered(address indexed token, uint256 previousBps, uint256 newBps);
    event CreatorStatusChanged(address indexed token, bool active);
    event VerifierSet(address indexed verifier);
    event RunPriceSet(uint256 previousPrice, uint256 newPrice);
    event Reimbursed(
        address indexed token, bytes32 indexed jobRef, address indexed creator, bytes32 commit, uint256 amount
    );
    event RunVerified(address indexed token, bytes32 indexed jobRef, bytes32 indexed commit, uint256 amount);
    event CloseAnnounced(address indexed token, uint256 noticeAt, uint256 earliestClose);
    event CloseCancelled(address indexed token);
    event Closed(address indexed token, uint256 snapshotBlock, uint256 poolAtClose, uint256 circulating);
    event Claimed(address indexed token, address indexed holder, uint256 amount);
    event CreatorClaimed(address indexed token, address indexed creator, uint256 amount);
    event TeamClaimed(address indexed owner, uint256 amount);

    constructor(address owner_) Ownable(owner_) {}

    function project(address token) external view returns (Project memory) {
        return _projects[token];
    }

    function wire(address factory_) external onlyOwner {
        if (factory != address(0)) revert AlreadyWired();
        if (factory_ == address(0)) revert InvalidAddress();
        if (IKeelFactory(factory_).vault() != address(this)) revert InvalidFactory();
        address hook_ = IKeelFactory(factory_).hook();
        if (
            hook_ == address(0) || IKeelHook(hook_).factory() != factory_
                || IKeelHook(hook_).vault() != address(this)
        ) {
            revert InvalidFactory();
        }
        factory = factory_;
        hook = hook_;
        emit Wired(factory_, hook_);
    }

    function register(
        address token,
        address creator,
        bytes32 jobHash,
        bytes32 projectHash,
        uint256 creatorBps
    ) external {
        if (factory == address(0)) revert NotConfigured();
        if (msg.sender != factory) revert Unauthorized();
        if (token == address(0) || creator == address(0)) revert InvalidAddress();
        if (creatorBps > 8000) revert InvalidShare();
        if (_projects[token].creator != address(0) || buildingToken[creator] != address(0)) {
            revert CreatorHasBuildingToken();
        }
        _projects[token] = Project({
            creator: creator,
            phase: Phase.Building,
            creatorActive: true,
            creatorBps: uint16(creatorBps),
            launchedAt: uint64(block.timestamp),
            closeNotice: 0,
            basket: 0,
            creatorAccrued: 0,
            snapshotBlock: 0,
            poolAtClose: 0,
            circulating: 0,
            totalClaimed: 0,
            jobHash: jobHash,
            projectHash: projectHash
        });
        buildingToken[creator] = token;
        emit Registered(token, creator, jobHash, projectHash, creatorBps);
    }

    /// @dev The hook transfers IMD before calling. No tokens move here; intentionally callable during
    /// guarded close/share/status operations, which first flush the immutable hook's pending fees.
    function accrue(address token, uint256 amount) external {
        if (msg.sender != hook || hook == address(0)) revert Unauthorized();
        Project storage p = _known(token);
        if (amount == 0) revert InvalidAmount();
        uint256 team = Math.mulDiv(amount, TEAM_BPS, 10000);
        uint256 creator = 0;
        uint256 basket = 0;
        if (p.phase == Phase.Closed) {
            creator = amount - team;
        } else {
            if (p.creatorActive) creator = Math.mulDiv(amount, p.creatorBps, 10000);
            basket = amount - team - creator;
        }
        teamAccrued += team;
        p.creatorAccrued += creator;
        p.basket += basket;
        totalOwed += amount;
        if (imd.balanceOf(address(this)) < totalOwed) revert Insolvent();
        emit FeeAccrued(token, amount, team, creator, basket);
    }

    function lowerCreatorShare(address token, uint256 newBps) external nonReentrant {
        Project storage p = _building(token);
        if (msg.sender != p.creator) revert Unauthorized();
        if (newBps >= p.creatorBps) revert InvalidShare();
        IKeelHook(hook).distribute(token);
        uint256 previous = p.creatorBps;
        p.creatorBps = uint16(newBps);
        emit CreatorShareLowered(token, previous, newBps);
    }

    function setCreatorActive(address token, bool active) external onlyOwner nonReentrant {
        Project storage p = _building(token);
        IKeelHook(hook).distribute(token);
        p.creatorActive = active;
        emit CreatorStatusChanged(token, active);
    }

    function setVerifier(address verifier_) external onlyOwner {
        if (verifier_ == address(0)) revert InvalidAddress();
        verifier = verifier_;
        emit VerifierSet(verifier_);
    }

    function revokeVerifier() external onlyOwner {
        verifier = address(0);
        emit VerifierSet(address(0));
    }

    function setRunPrice(uint256 price) external onlyOwner {
        if (price < 0.1 ether || price > 2 ether) revert InvalidRunPrice();
        uint256 previous = runPrice;
        runPrice = price;
        emit RunPriceSet(previous, price);
    }

    function deposit(address token, uint256 amount) external nonReentrant {
        Project storage p = _building(token);
        if (amount == 0) revert InvalidAmount();
        uint256 beforeBalance = imd.balanceOf(address(this));
        p.basket += amount;
        totalOwed += amount;
        emit Deposited(token, msg.sender, amount);
        imd.safeTransferFrom(msg.sender, address(this), amount);
        if (imd.balanceOf(address(this)) != beforeBalance + amount) revert Insolvent();
    }

    function reimburse(address token, bytes32 jobRef, bytes32 commit, uint256 amount) external nonReentrant {
        _verifier();
        Project storage p = _building(token);
        if (!p.creatorActive) revert InactiveCreator();
        _checkRun(jobRef, commit);
        if (amount == 0 || amount > runPrice) revert InvalidAmount();
        if (p.basket < amount) revert InsufficientBasket();
        jobUsed[jobRef] = true;
        p.basket -= amount;
        totalOwed -= amount;
        emit Reimbursed(token, jobRef, p.creator, commit, amount);
        emit RunVerified(token, jobRef, commit, amount);
        imd.safeTransfer(p.creator, amount);
    }

    function recordRun(address token, bytes32 jobRef, bytes32 commit) external nonReentrant {
        _verifier();
        Project storage p = _building(token);
        _checkRun(jobRef, commit);
        if (p.creatorActive && p.basket >= runPrice) revert ReimbursementAvailable();
        jobUsed[jobRef] = true;
        emit RunVerified(token, jobRef, commit, 0);
    }

    function announceClose(address token) external onlyOwner {
        Project storage p = _building(token);
        if (p.closeNotice != 0) revert NoticeExists();
        p.closeNotice = uint64(block.timestamp);
        emit CloseAnnounced(
            token,
            block.timestamp,
            Math.max(block.timestamp + CLOSE_NOTICE, uint256(p.launchedAt) + MIN_LIFETIME)
        );
    }

    function cancelClose(address token) external onlyOwner {
        Project storage p = _building(token);
        if (p.closeNotice == 0) revert NoNotice();
        p.closeNotice = 0;
        emit CloseCancelled(token);
    }

    function close(address token) external onlyOwner nonReentrant {
        Project storage p = _building(token);
        if (
            p.closeNotice == 0 || block.timestamp < uint256(p.closeNotice) + CLOSE_NOTICE
                || block.timestamp < uint256(p.launchedAt) + MIN_LIFETIME || block.number == 0
        ) revert CloseNotReady();
        IKeelHook(hook).distribute(token);
        uint256 snapshot = block.number - 1;
        IKeelToken t = IKeelToken(token);
        uint256 circulating =
            t.totalSupply() - t.balanceAt(C.POOL_MANAGER, snapshot) - t.balanceAt(C.DEAD, snapshot);
        p.phase = Phase.Closed;
        p.snapshotBlock = snapshot;
        p.poolAtClose = p.basket;
        p.circulating = circulating;
        buildingToken[p.creator] = address(0);
        emit Closed(token, snapshot, p.poolAtClose, circulating);
    }

    function claimable(address token, address holder) public view returns (uint256) {
        Project storage p = _projects[token];
        if (
            p.phase != Phase.Closed || p.circulating == 0 || claimed[token][holder]
                || holder == C.POOL_MANAGER || holder == C.DEAD
        ) return 0;
        return Math.mulDiv(p.poolAtClose, IKeelToken(token).balanceAt(holder, p.snapshotBlock), p.circulating);
    }

    function claim(address token) external nonReentrant returns (uint256 amount) {
        amount = claimable(token, msg.sender);
        if (amount == 0) revert NothingToClaim();
        Project storage p = _projects[token];
        claimed[token][msg.sender] = true;
        p.totalClaimed += amount;
        p.basket -= amount;
        totalOwed -= amount;
        emit Claimed(token, msg.sender, amount);
        imd.safeTransfer(msg.sender, amount);
    }

    function claimCreator(address token) external nonReentrant returns (uint256 amount) {
        Project storage p = _known(token);
        if (msg.sender != p.creator) revert Unauthorized();
        amount = p.creatorAccrued;
        if (amount == 0) revert NothingToClaim();
        p.creatorAccrued = 0;
        totalOwed -= amount;
        emit CreatorClaimed(token, p.creator, amount);
        imd.safeTransfer(p.creator, amount);
    }

    function claimTeam() external onlyOwner nonReentrant returns (uint256 amount) {
        amount = teamAccrued;
        if (amount == 0) revert NothingToClaim();
        teamAccrued = 0;
        totalOwed -= amount;
        emit TeamClaimed(owner(), amount);
        imd.safeTransfer(owner(), amount);
    }

    function _known(address token) private view returns (Project storage p) {
        p = _projects[token];
        if (p.creator == address(0)) revert UnknownToken();
    }

    function _building(address token) private view returns (Project storage p) {
        p = _known(token);
        if (p.phase != Phase.Building) revert NotBuilding();
    }

    function _verifier() private view {
        if (verifier == address(0)) revert NotConfigured();
        if (msg.sender != verifier) revert Unauthorized();
    }

    function _checkRun(bytes32 jobRef, bytes32 commit) private view {
        if (jobRef == bytes32(0) || commit == bytes32(0)) revert InvalidRun();
        if (jobUsed[jobRef]) revert JobAlreadyUsed();
    }
}
