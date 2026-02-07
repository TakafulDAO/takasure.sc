// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {StrategyConfig} from "contracts/types/Strategies.sol";

contract MockVaultLens {
    struct LastReport {
        uint256 ts;
        uint256 assets;
    }

    mapping(address => uint256) public idleAssetsOf;
    mapping(address => LastReport) public lastReportOf;
    mapping(address => uint256) public aggregatorAllocationOf;
    mapping(address => uint256) public aggregatorAssetsOf;
    mapping(address => uint256) public vaultTVLOf;

    mapping(address => mapping(address => uint256)) public userAssetsOf;
    mapping(address => mapping(address => uint256)) public userSharesOf;
    mapping(address => mapping(address => uint256)) public userTotalDepositedOf;
    mapping(address => mapping(address => uint256)) public userTotalWithdrawnOf;
    mapping(address => mapping(address => uint256)) public userNetDepositedOf;
    mapping(address => mapping(address => int256)) public userPnLOf;
    mapping(address => mapping(uint256 => int256)) public vaultPerformanceSinceOf;

    function setIdleAssets(address vault, uint256 v) external {
        idleAssetsOf[vault] = v;
    }

    function setLastReport(address vault, uint256 ts, uint256 assets) external {
        lastReportOf[vault] = LastReport({ts: ts, assets: assets});
    }

    function setAggregatorAllocation(address vault, uint256 v) external {
        aggregatorAllocationOf[vault] = v;
    }

    function setAggregatorAssets(address vault, uint256 v) external {
        aggregatorAssetsOf[vault] = v;
    }

    function setVaultTVL(address vault, uint256 v) external {
        vaultTVLOf[vault] = v;
    }

    function setUserAssets(address vault, address user, uint256 v) external {
        userAssetsOf[vault][user] = v;
    }

    function setUserShares(address vault, address user, uint256 v) external {
        userSharesOf[vault][user] = v;
    }

    function setUserTotalDeposited(address vault, address user, uint256 v) external {
        userTotalDepositedOf[vault][user] = v;
    }

    function setUserTotalWithdrawn(address vault, address user, uint256 v) external {
        userTotalWithdrawnOf[vault][user] = v;
    }

    function setUserNetDeposited(address vault, address user, uint256 v) external {
        userNetDepositedOf[vault][user] = v;
    }

    function setUserPnL(address vault, address user, int256 v) external {
        userPnLOf[vault][user] = v;
    }

    function setVaultPerformanceSince(address vault, uint256 ts, int256 v) external {
        vaultPerformanceSinceOf[vault][ts] = v;
    }

    function getIdleAssets(address vault) external view returns (uint256) {
        return idleAssetsOf[vault];
    }

    function getLastReport(address vault)
        external
        view
        returns (uint256 lastReportTimestamp, uint256 lastReportAssets)
    {
        LastReport memory r = lastReportOf[vault];
        return (r.ts, r.assets);
    }

    function getAggregatorAllocation(address vault) external view returns (uint256) {
        return aggregatorAllocationOf[vault];
    }

    function getAggregatorAssets(address vault) external view returns (uint256) {
        return aggregatorAssetsOf[vault];
    }

    function getUserAssets(address vault, address user) external view returns (uint256) {
        return userAssetsOf[vault][user];
    }

    function getUserShares(address vault, address user) external view returns (uint256) {
        return userSharesOf[vault][user];
    }

    function getUserTotalDeposited(address vault, address user) external view returns (uint256) {
        return userTotalDepositedOf[vault][user];
    }

    function getUserTotalWithdrawn(address vault, address user) external view returns (uint256) {
        return userTotalWithdrawnOf[vault][user];
    }

    function getUserNetDeposited(address vault, address user) external view returns (uint256) {
        return userNetDepositedOf[vault][user];
    }

    function getUserPnL(address vault, address user) external view returns (int256) {
        return userPnLOf[vault][user];
    }

    function getVaultPerformanceSince(address vault, uint256 timestamp) external view returns (int256) {
        return vaultPerformanceSinceOf[vault][timestamp];
    }

    function getVaultTVL(address vault) external view returns (uint256) {
        return vaultTVLOf[vault];
    }

    function test() public view {}
}

contract MockAggregatorLens {
    mapping(address => StrategyConfig) public configOf;
    mapping(address => uint256) public positionValueOf;
    mapping(address => bytes) public positionDetailsOf;

    function setConfig(address aggregator, StrategyConfig calldata cfg) external {
        configOf[aggregator] = cfg;
    }

    function setPositionValue(address aggregator, uint256 v) external {
        positionValueOf[aggregator] = v;
    }

    function setPositionDetails(address aggregator, bytes calldata v) external {
        positionDetailsOf[aggregator] = v;
    }

    function getConfig(address aggregator) external view returns (StrategyConfig memory) {
        return configOf[aggregator];
    }

    function positionValue(address aggregator) external view returns (uint256) {
        return positionValueOf[aggregator];
    }

    function getPositionDetails(address aggregator) external view returns (bytes memory) {
        return positionDetailsOf[aggregator];
    }

    function test() public view {}
}

contract MockUniswapLens {
    mapping(address => StrategyConfig) public configOf;
    mapping(address => uint256) public positionValueOf;
    mapping(address => bytes) public positionDetailsOf;

    function setConfig(address strategy, StrategyConfig calldata cfg) external {
        configOf[strategy] = cfg;
    }

    function setPositionValue(address strategy, uint256 v) external {
        positionValueOf[strategy] = v;
    }

    function setPositionDetails(address strategy, bytes calldata v) external {
        positionDetailsOf[strategy] = v;
    }

    function getConfig(address strategy) external view returns (StrategyConfig memory) {
        return configOf[strategy];
    }

    function positionValue(address strategy) external view returns (uint256) {
        return positionValueOf[strategy];
    }

    function getPositionDetails(address strategy) external view returns (bytes memory) {
        return positionDetailsOf[strategy];
    }

    function test() public view {}
}
