// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

// Functions calles by keepers / algos for strategy maintenance tasks.
interface ISFStrategyMaintenance {
    function harvest(bytes calldata data) external;
    function rebalance(bytes calldata data) external;
}

