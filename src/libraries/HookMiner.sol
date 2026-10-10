// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelConstants as C} from "./KeelConstants.sol";

library HookMiner {
    /// @dev Allocate the 85-byte CREATE2 preimage once. Each iteration changes only its salt.
    /// There are 14 constrained address bits; the expected search length is 16,384 hashes.
    function find(address deployer, bytes32 initCodeHash, uint256 start)
        internal
        pure
        returns (bytes32 salt, address predicted, uint256 attempts)
    {
        uint256 flags = C.HOOK_FLAGS;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(0x40, add(ptr, 0x60))
            mstore(ptr, or(shl(248, 0xff), shl(88, deployer)))
            mstore(add(ptr, 53), initCodeHash)
            salt := start
            for {} 1 { salt := add(salt, 1) } {
                mstore(add(ptr, 21), salt)
                predicted := and(keccak256(ptr, 85), 0xffffffffffffffffffffffffffffffffffffffff)
                attempts := add(attempts, 1)
                if eq(and(predicted, 0x3fff), flags) { break }
            }
        }
    }
}
