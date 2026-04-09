// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/**
 * @title ISaveFundsInvestAutomationRunnerExecutor
 * @notice Minimal external interface used by the CRE receiver to trigger the runner.
 */
interface ISaveFundsInvestAutomationRunnerExecutor {
    /**
     * @notice Executes an upkeep cycle.
     * @param performData Chainlink Automation-compatible payload.
     */
    function performUpkeep(bytes calldata performData) external;
}
