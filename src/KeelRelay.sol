// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

interface IKeelRelayVault {
    /// @dev ABI-identical to KeelVault.Project (its Phase enum is a uint8).
    struct Project {
        address creator;
        uint8 phase;
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

    function project(address token) external view returns (Project memory);
    function reimburse(address token, bytes32 jobRef, bytes32 commit, uint256 amount) external;
    function recordRun(address token, bytes32 jobRef, bytes32 commit) external;
}

interface IKeelRelayHook {
    function distribute(address token) external;
}

/// @notice The KeelVault verifier, so that the people who gain from a verified run pay its gas.
/// The Keel server checks each IMD continuation off chain and signs vouchers for each run; the
/// creator submits one here and this contract makes the vault call. The vault still pays only the
/// creator recorded on chain and still uses each jobRef once.
/// A voucher with an amount reimburses it from the basket; anyone may submit it, since the payout
/// can only reach the creator. A voucher with amount 0 records the run without a payout and uses up
/// its jobRef for good, so only the token's creator or the relay owner may submit it: published
/// vouchers must not let a stranger cancel a creator's payout while the basket is still filling.
/// Both kinds first move the hook's pending fees into the basket, so the vault's "the basket cannot
/// pay a run" rule for recording sees every fee already earned.
contract KeelRelay is Ownable2Step, EIP712 {
    bytes32 public constant RUN_TYPEHASH =
        keccak256("Run(address token,bytes32 jobRef,bytes32 commit,uint256 amount)");

    IKeelRelayVault public immutable vault;
    IKeelRelayHook public immutable hook;
    address public signer;

    error InvalidAddress();
    error InvalidSignature();
    error RecordNotAllowed();

    event SignerSet(address indexed signer);
    event RunSubmitted(address indexed token, bytes32 indexed jobRef, address indexed sender, uint256 amount);

    constructor(address owner_, address vault_, address hook_, address signer_)
        Ownable(owner_)
        EIP712("KeelRelay", "1")
    {
        if (vault_ == address(0) || hook_ == address(0) || signer_ == address(0)) {
            revert InvalidAddress();
        }
        vault = IKeelRelayVault(vault_);
        hook = IKeelRelayHook(hook_);
        signer = signer_;
        emit SignerSet(signer_);
    }

    function setSigner(address signer_) external onlyOwner {
        if (signer_ == address(0)) revert InvalidAddress();
        signer = signer_;
        emit SignerSet(signer_);
    }

    /// @notice Stops every outstanding voucher at once.
    function revokeSigner() external onlyOwner {
        signer = address(0);
        emit SignerSet(address(0));
    }

    function runDigest(address token, bytes32 jobRef, bytes32 commit, uint256 amount)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(RUN_TYPEHASH, token, jobRef, commit, amount)));
    }

    function submit(address token, bytes32 jobRef, bytes32 commit, uint256 amount, bytes calldata signature)
        external
    {
        address s = signer;
        if (
            s == address(0)
                || !SignatureChecker.isValidSignatureNow(
                    s, runDigest(token, jobRef, commit, amount), signature
                )
        ) {
            revert InvalidSignature();
        }
        if (amount == 0 && msg.sender != owner() && msg.sender != vault.project(token).creator) {
            revert RecordNotAllowed();
        }
        emit RunSubmitted(token, jobRef, msg.sender, amount);
        hook.distribute(token);
        if (amount == 0) {
            vault.recordRun(token, jobRef, commit);
        } else {
            vault.reimburse(token, jobRef, commit, amount);
        }
    }
}
