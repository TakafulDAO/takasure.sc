// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

interface ISFVaultLens {
    function getIdleAssets(address vault) external view returns (uint256);
    function getLastReport(address vault) external view returns (uint256 lastReportTimestamp, uint256 lastReportAssets);
    function getAggregatorAllocation(address vault) external view returns (uint256);
    function getAggregatorAssets(address vault) external view returns (uint256);
    function getUserAssets(address vault, address user) external view returns (uint256);
    function getUserShares(address vault, address user) external view returns (uint256);
    function getUserTotalDeposited(address vault, address user) external view returns (uint256);
    function getUserTotalWithdrawn(address vault, address user) external view returns (uint256);
    function getUserNetDeposited(address vault, address user) external view returns (uint256);
    function getUserPnL(address vault, address user) external view returns (int256);
    function getVaultPerformanceSince(address vault, uint256 timestamp) external view returns (int256);
    function getVaultTVL(address vault) external view returns (uint256);
}
