// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

interface ISFVault {
    event OnFeesTaken(uint256 feeRecipient, uint256 feeAssetsOrShares, uint256 feeType);
    event OnStrategyUpdated(address indexed newStrategy, uint256 newCap, bool active);
    event OnTVLCapUpdated(uint256 newCap);

    function getUserAssets(address user) external view returns (uint256);
    function getUserShares(address user) external view returns (uint256);
    function getUserTotalDeposited(address user) external view returns (uint256);
    function getUserTotalWithdrawn(address user) external view returns (uint256);
    function getUserNetDeposited(address user) external view returns (uint256);
    function getUserPnL(address user) external view returns (int256);
    function getVaultTVL() external view returns (uint256);
    function getIdleAssets() external view returns (uint256);
    function getStrategyAssets() external view returns (uint256);
    function getStrategyAllocation() external view returns (uint256);
    function getVaultPerformanceSince(uint256 timestamp) external view returns (int256);
    function investIntoStrategy(address strategy, uint256 assets) external;
    function withdrawFromStrategy(address strategy, uint256 assets) external;
    function rebalance(address fromStrategy, address toStrategy, uint256 assets) external;
    function harvest(address strategy) external;
    function getLastReport() external view returns (uint256 lastReportTimestamp, uint256 lastReportAssets);
}
