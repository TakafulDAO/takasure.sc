// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

// Functions calles by keepers / algos for strategy maintenance tasks.
interface ISFStrategyMaintenance {
    // todo: in future use only one file for this ISaveFundStrategyMaintenance
    /// @notice Realize fees, claim rewards, maybe swap them back to USDC, and reinvest.
    // todo: remember to add this access restriction in implementation. onlyKeeper or onlyGovernance or something like that
    function harvest(bytes calldata data) external;

    /// @notice Adjust the position: move range, change liquidity distribution, or change target ratios.
    // todo: remember to add this access restriction in implementation. onlyKeeper or onlyGovernance or something like that
    function rebalance(bytes calldata data) external;
}

