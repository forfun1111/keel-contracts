// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {KeelConstants as C} from "./libraries/KeelConstants.sol";

/// @notice Immutable-supply EIP-1167 implementation. Only clones can initialize.
contract KeelToken is ERC20 {
    using Checkpoints for Checkpoints.Trace208;

    bool private _initialized;
    string private _tokenName;
    string private _tokenSymbol;
    mapping(address => Checkpoints.Trace208) private _balancesAt;

    error AlreadyInitialized();
    error InvalidInitialization();
    error FutureLookup();

    constructor() ERC20("", "") {
        _initialized = true;
    }

    function initialize(string calldata name_, string calldata symbol_, address to) external {
        if (_initialized) revert AlreadyInitialized();
        if (to == address(0) || bytes(name_).length == 0 || bytes(symbol_).length == 0) {
            revert InvalidInitialization();
        }
        _initialized = true;
        _tokenName = name_;
        _tokenSymbol = symbol_;
        _mint(to, C.SUPPLY);
    }

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    /// @dev The current block is excluded, including transfers earlier in the same block.
    function balanceAt(address account, uint256 pastBlock) external view returns (uint256) {
        if (pastBlock >= block.number) revert FutureLookup();
        return _balancesAt[account].upperLookupRecent(SafeCast.toUint48(pastBlock));
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0)) _checkpoint(from);
        if (to != address(0) && to != from) _checkpoint(to);
    }

    function _checkpoint(address account) private {
        uint208 balance = SafeCast.toUint208(balanceOf(account));
        (uint208 previous, uint208 current) =
            _balancesAt[account].push(SafeCast.toUint48(block.number), balance);
        // A checkpoint must reflect a possible fixed-supply balance, including self-transfers.
        assert(previous <= C.SUPPLY && current == balance);
    }
}
