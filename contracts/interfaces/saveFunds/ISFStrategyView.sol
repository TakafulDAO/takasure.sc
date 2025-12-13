// SPDX-License-Identifier: GPL-3.0-only

import {StrategyConfig} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;

// Debugging and view functions for strategies.
interface ISFStrategyView {
    function getConfig() external view returns (StrategyConfig memory);

    /// @notice Value of the active position in USDC (totalAssets - idleAssets).
    function positionValue() external view returns (uint256);

    /// @notice Implementation-specific introspection, e.g. Uniswap ticks, liquidity
    /// Could be overridden in child strategies with more detailed info.
    function getPositionDetails() external view returns (bytes memory);
}

