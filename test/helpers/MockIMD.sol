// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockIMD is ERC20 {
    bool public failTransfers;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bool private _calling;
    uint256 public taxBps;

    constructor() ERC20("IMD test fixture", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailTransfers(bool fail) external {
        failTransfers = fail;
    }

    function setTax(uint256 bps) external {
        taxBps = bps;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
        callbackSucceeded = false;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(!failTransfers, "IMD transfer failed");
        uint256 tax = from != address(0) && to != address(0) ? amount * taxBps / 10000 : 0;
        if (tax != 0) super._update(from, address(0), tax);
        super._update(from, to, amount - tax);
        if (!_calling && callbackTarget != address(0)) {
            _calling = true;
            (bool ok,) = callbackTarget.call(callbackData);
            callbackSucceeded = ok;
            _calling = false;
        }
    }
}
