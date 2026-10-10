// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library KeelConstants {
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant SUPPLY = 1e27;
    int24 internal constant TICK_SPACING = 200;
    int24 internal constant MAX_TICK = 887200;
    int24 internal constant MIN_TICK = -887200;
    uint160 internal constant HOOK_FLAGS = 0x28cc;
}
