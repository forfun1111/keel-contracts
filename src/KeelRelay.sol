// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

interface IKeelRelayVault {
    function reimburse(address token, bytes32 jobRef, bytes32 commit, uint256 amount) external;
    function recordRun(address token, bytes32 jobRef, bytes32 commit) external;
}

interface IKeelRelayHook {
    function distribute(address token) external;
}

/// @notice The KeelVault verifier, so that the people who gain from a verified run pay its gas.
/// The Keel server checks each IMD continuation off chain and signs one voucher per run; anyone
/// (normally the creator) submits it here and this contract makes the vault call. The vault still
/// pays only the creator recorded on chain and still uses each jobRef once, so a voucher can be
/// submitted by anyone, but only once.
/// A voucher with an amount reimburses it from the basket after moving the hook's pending fees in;
/// a voucher with amount 0 records the run without a payout (the vault allows that only while the
/// basket cannot pay a run, or the creator is inactive).
contract KeelRelay is Ownable2Step, EIP712 {
    bytes32 public constant RUN_TYPEHASH =
        keccak256("Run(address token,bytes32 jobRef,bytes32 commit,uint256 amount)");

    IKeelRelayVault public immutable vault;
    IKeelRelayHook public immutable hook;
    address public signer;

    error InvalidAddress();
    error InvalidSignature();

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
        emit RunSubmitted(token, jobRef, msg.sender, amount);
        if (amount == 0) {
            vault.recordRun(token, jobRef, commit);
        } else {
            hook.distribute(token);
            vault.reimburse(token, jobRef, commit, amount);
        }
    }
}
