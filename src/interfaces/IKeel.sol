// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface IKeelToken {
    function initialize(string calldata name, string calldata symbol, address to) external;
    function balanceAt(address account, uint256 pastBlock) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IKeelHook {
    function distribute(address token) external;
    function factory() external view returns (address);
    function vault() external view returns (address);
}

interface IKeelVault {
    function accrue(address token, uint256 amount) external;
    function register(
        address token,
        address creator,
        bytes32 jobHash,
        bytes32 projectHash,
        uint256 creatorBps
    ) external;
    function buildingToken(address creator) external view returns (address);
    function factory() external view returns (address);
}

interface IKeelFactory {
    function vault() external view returns (address);
    function hook() external view returns (address);
    function isLaunched(address token) external view returns (bool);
    function poolKey(address token) external view returns (PoolKey memory);
}
