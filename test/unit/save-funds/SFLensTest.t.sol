// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SFLens} from "contracts/saveFunds/SFLens.sol";
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

    function getLastReport(address vault) external view returns (uint256 lastReportTimestamp, uint256 lastReportAssets) {
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
}

contract SFLensTest is Test {
    MockVaultLens internal vaultLens;
    MockAggregatorLens internal aggregatorLens;
    MockUniswapLens internal uniswapLens;
    SFLens internal lens;

    function setUp() public {
        vaultLens = new MockVaultLens();
        aggregatorLens = new MockAggregatorLens();
        uniswapLens = new MockUniswapLens();

        lens = new SFLens(address(vaultLens), address(aggregatorLens), address(uniswapLens));
    }

    function testSFLens_constructor_RevertsOnZeroAddress() public {
        vm.expectRevert(SFLens.SFLens__NotAddressZero.selector);
        new SFLens(address(0), address(aggregatorLens), address(uniswapLens));
    }

    function testSFLens_ForwardsToUnderlyingLenses() public {
        address vault = makeAddr("vault");
        address user = makeAddr("user");
        address aggregator = makeAddr("aggregator");
        address strategy = makeAddr("strategy");

        vaultLens.setIdleAssets(vault, 111);
        vaultLens.setLastReport(vault, 1000, 2000);
        vaultLens.setAggregatorAllocation(vault, 333);
        vaultLens.setAggregatorAssets(vault, 444);
        vaultLens.setUserAssets(vault, user, 555);
        vaultLens.setUserShares(vault, user, 666);
        vaultLens.setUserTotalDeposited(vault, user, 777);
        vaultLens.setUserTotalWithdrawn(vault, user, 888);
        vaultLens.setUserNetDeposited(vault, user, 999);
        vaultLens.setUserPnL(vault, user, -123);
        vaultLens.setVaultPerformanceSince(vault, 12345, 42);
        vaultLens.setVaultTVL(vault, 314);

        StrategyConfig memory aggCfg =
            StrategyConfig({asset: address(0xAA), vault: address(0xBB), pool: address(0xCC), paused: true});
        StrategyConfig memory uniCfg =
            StrategyConfig({asset: address(0x11), vault: address(0x22), pool: address(0x33), paused: false});

        aggregatorLens.setConfig(aggregator, aggCfg);
        aggregatorLens.setPositionValue(aggregator, 123);
        aggregatorLens.setPositionDetails(aggregator, hex"deadbeef");

        uniswapLens.setConfig(strategy, uniCfg);
        uniswapLens.setPositionValue(strategy, 456);
        uniswapLens.setPositionDetails(strategy, hex"c0ffee");

        assertEq(lens.vaultGetIdleAssets(vault), 111);

        (uint256 ts, uint256 assets) = lens.vaultGetLastReport(vault);
        assertEq(ts, 1000);
        assertEq(assets, 2000);

        assertEq(lens.vaultGetAggregatorAllocation(vault), 333);
        assertEq(lens.vaultGetAggregatorAssets(vault), 444);
        assertEq(lens.vaultGetUserAssets(vault, user), 555);
        assertEq(lens.vaultGetUserShares(vault, user), 666);
        assertEq(lens.vaultGetUserTotalDeposited(vault, user), 777);
        assertEq(lens.vaultGetUserTotalWithdrawn(vault, user), 888);
        assertEq(lens.vaultGetUserNetDeposited(vault, user), 999);
        assertEq(lens.vaultGetUserPnL(vault, user), -123);
        assertEq(lens.vaultGetVaultPerformanceSince(vault, 12345), 42);
        assertEq(lens.vaultGetVaultTVL(vault), 314);

        StrategyConfig memory aggCfgOut = lens.aggregatorGetConfig(aggregator);
        assertEq(aggCfgOut.asset, aggCfg.asset);
        assertEq(aggCfgOut.vault, aggCfg.vault);
        assertEq(aggCfgOut.pool, aggCfg.pool);
        assertEq(aggCfgOut.paused, aggCfg.paused);

        assertEq(lens.aggregatorGetPositionValue(aggregator), 123);
        assertEq(lens.aggregatorGetPositionDetails(aggregator), hex"deadbeef");

        StrategyConfig memory uniCfgOut = lens.uniswapGetConfig(strategy);
        assertEq(uniCfgOut.asset, uniCfg.asset);
        assertEq(uniCfgOut.vault, uniCfg.vault);
        assertEq(uniCfgOut.pool, uniCfg.pool);
        assertEq(uniCfgOut.paused, uniCfg.paused);

        assertEq(lens.uniswapGetPositionValue(strategy), 456);
        assertEq(lens.uniswapGetPositionDetails(strategy), hex"c0ffee");
    }
}
