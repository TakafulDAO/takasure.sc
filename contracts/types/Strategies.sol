// SPDX-License-Identifier: GNU GPLv3

import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";

pragma solidity 0.8.28;

struct StrategyConfig {
    address asset; // USDC
    address vault;
    address pool; // e.g. Uniswap v3/v4 pool
    bool paused;
    // optional: strategy type enum, fee params, slippage limits, etc.
}

struct SubStrategy {
    ISFStrategy strategy;
    uint16 targetWeightBPS; // 0 to 10000 (0% to 100%)
    bool isActive;
}
