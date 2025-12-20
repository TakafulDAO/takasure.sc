// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

interface ISFVault {
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
    function getLastReport() external view returns (uint256 lastReportTimestamp, uint256 lastReportAssets);
    function isTokenWhitelisted(address token) external view returns (bool);
    function whitelistedTokensLength() external view returns (uint256);
    function getWhitelistedTokens() external view returns (address[] memory);
    function investIntoStrategy(uint256 assets, address[] calldata strategies, bytes[] calldata payloads)
        external
        returns (uint256 investedAssets);
    function withdrawFromStrategy(uint256 assets, address[] calldata strategies, bytes[] calldata payloads)
        external
        returns (uint256 withdrawnAssets);
}
