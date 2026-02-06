// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SFLens} from "contracts/saveFunds/SFLens.sol";
import {StrategyConfig} from "contracts/types/Strategies.sol";
import {MockVaultLens, MockAggregatorLens, MockUniswapLens} from "test/mocks/MockLens.sol";

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
