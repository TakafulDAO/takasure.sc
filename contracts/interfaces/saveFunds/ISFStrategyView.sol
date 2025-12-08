// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

struct StrategyConfig {
    address asset; // USDC
    address vault;
    address keeper;
    address pool; // e.g. Uniswap v3/v4 pool
    uint256 maxTVL;
    bool paused;
    // optional: strategy type enum, fee params, slippage limits, etc.
}

// Debugging and view functions for strategies.
interface ISFStrategyView {
    function getConfig() external view returns (StrategyConfig memory);

    /// @notice Value of the active position in USDC (totalAssets - idleAssets).
    function positionValue() external view returns (uint256);

    /// @notice Implementation-specific introspection, e.g. Uniswap ticks, liquidity
    /// Could be overridden in child strategies with more detailed info.
    function getPositionDetails() external view returns (bytes memory);
}

