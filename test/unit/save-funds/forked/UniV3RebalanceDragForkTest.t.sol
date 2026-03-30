// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {SFVault} from "contracts/saveFunds/protocol/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/protocol/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/protocol/SFUniswapV3Strategy.sol";
import {SFUniswapV3SwapRouterHelper} from "contracts/helpers/uniswapHelpers/SFUniswapV3SwapRouterHelper.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";

contract UniV3RebalanceDragForkTest is Test {
    struct RebalanceDragMetrics {
        int24 oldTickLower;
        int24 oldTickUpper;
        int24 newTickLower;
        int24 newTickUpper;
        int24 spotTickBefore;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        uint256 dragApproxUsd;
    }

    struct SwapDragBreakdown {
        uint24 feePips;
        uint256 totalDragApproxUsd;
        uint256 feeCostApproxUsd;
        uint256 nonFeeCostApproxUsd;
    }

    struct RouteSelectionMetrics {
        uint256 amountIn;
        uint256 v3QuotedOut;
        uint256 v4QuotedOut;
        uint8 selectedRouteId;
    }

    struct StrategyGuardrailScenario {
        uint32 twapWindow;
        uint16 swapSlippageBps;
    }

    struct TickRangeScenario {
        int24 lowerOffset;
        int24 upperOffset;
    }

    struct TickRangeBaseline {
        uint256 amountIn;
        uint256 legacyAmountOut;
        uint256 upgradedAmountOut;
        uint256 legacyDrag;
        uint256 upgradedDrag;
        uint256 v3QuotedOut;
        uint256 v4QuotedOut;
        uint8 selectedRouteId;
    }

    uint256 internal constant HISTORICAL_BLOCK = 446153833;
    int24 internal constant HISTORICAL_NEW_TICK_LOWER = 1;
    int24 internal constant HISTORICAL_NEW_TICK_UPPER = 6;
    uint16 internal constant HISTORICAL_OTHER_RATIO_BPS = 5_245;
    uint256 internal constant HISTORICAL_PM_DEADLINE = 1_774_606_087;
    uint256 internal constant HISTORICAL_SWAP_DEADLINE = 0;
    uint16 internal constant MAX_BPS = 10_000;
    uint256 internal constant AMOUNT_IN_BPS_FLAG = uint256(1) << 255;
    string internal constant SWAP_ROUTER_HELPER_NAME = "HELPER__SF_SWAP_ROUTER";
    uint8 internal constant ROUTE_V3_SINGLE_HOP = 1;
    uint8 internal constant ROUTE_V4_SINGLE_HOP = 2;
    bytes32 internal constant ON_SWAP_EXECUTED_SIG = keccak256("OnSwapExecuted(address,address,uint256,uint256)");
    bytes32 internal constant ON_SWAP_ROUTES_COMPARED_SIG =
        keccak256("OnSwapRoutesCompared(uint256,uint256,uint256,uint8)");
    address internal constant NONFUNGIBLE_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    uint24 internal constant SWAP_V4_POOL_FEE = 8;
    int24 internal constant SWAP_V4_POOL_TICK_SPACING = 1;
    address internal constant SWAP_V4_POOL_HOOKS = address(0);

    ForkAddressGetter internal addrGetter;
    AddressManager internal addrMgr;
    SFVault internal vault;
    SFStrategyAggregator internal aggregator;
    SFUniswapV3Strategy internal uniV3;
    IERC20 internal underlying;
    IERC20 internal otherToken;
    IUniswapV3Pool internal pool;
    RouteSelectionMetrics internal lastRouteSelectionMetrics;

    address internal operator;
    address internal pauseGuardian;

    function setUp() public {}

    // It test pre upgrade at the moment the last rebalance happened, at block 446153833.
    // The drag here is `legacy.dradApproxUsd
    function testForkHistorical_rebalanceLegacyPath_CharacterizesSwapDrag() public {
        RebalanceDragMetrics memory legacy = _runHistoricalRebalanceScenario(false);

        console2.log("legacy drag in USD approx (6 decimals):", legacy.dragApproxUsd); // 4_407_356
        console2.log("legacy amountIn:", legacy.amountIn); // 9_525_563_619
        console2.log("legacy amountOut:", legacy.amountOut); // 9_521_156_263
        console2.logInt(legacy.spotTickBefore);

        assertGt(legacy.amountIn, 0, "legacy swap amountIn is zero");
        assertGt(legacy.amountOut, 0, "legacy swap amountOut is zero");
        assertGt(legacy.dragApproxUsd, 0, "legacy drag should be positive");
        assertGt(legacy.dragApproxUsd, 4_000_000, "legacy drag should be meaningful");
        assertLt(legacy.dragApproxUsd, 5_000_000, "legacy drag moved away from the historical range");
    }

    // This is post upgrade with the onchain route selection, at the same block
    function testForkHistorical_rebalance_OnchainBestRouteSelection_ReducesSwapDrag() public {
        RebalanceDragMetrics memory legacy = _runHistoricalRebalanceScenario(false);
        RebalanceDragMetrics memory upgraded = _runHistoricalRebalanceScenario(true);
        RouteSelectionMetrics memory routeSelection = lastRouteSelectionMetrics;

        console2.log("legacy drag in USD approx (6 decimals):", legacy.dragApproxUsd); // 4_407_356
        console2.log("upgraded drag in USD approx (6 decimals):", upgraded.dragApproxUsd); // 4_284_690
        console2.log("legacy amountIn:", legacy.amountIn); // 9_525_563_619
        console2.log("upgraded amountIn:", upgraded.amountIn); // 9_525_563_619
        console2.log("legacy amountOut:", legacy.amountOut); // 9_521_156_263
        console2.log("upgraded amountOut:", upgraded.amountOut); // 9_521_278_929
        console2.log("selected route id:", routeSelection.selectedRouteId); // 2 (V4 single hop)
        console2.log("quoted v3 amountOut:", routeSelection.v3QuotedOut); // 9_521_156_263
        console2.log("quoted v4 amountOut:", routeSelection.v4QuotedOut); // 9_521_278_929

        assertEq(upgraded.oldTickLower, legacy.oldTickLower, "old lower tick mismatch");
        assertEq(upgraded.oldTickUpper, legacy.oldTickUpper, "old upper tick mismatch");
        assertEq(upgraded.newTickLower, legacy.newTickLower, "new lower tick mismatch");
        assertEq(upgraded.newTickUpper, legacy.newTickUpper, "new upper tick mismatch");
        assertEq(upgraded.spotTickBefore, legacy.spotTickBefore, "spot tick mismatch");

        assertGt(legacy.dragApproxUsd, 0, "legacy drag should be positive");
        assertGt(upgraded.amountIn, 0, "upgraded swap amountIn is zero");
        assertGt(upgraded.amountOut, 0, "upgraded swap amountOut is zero");
        assertLt(upgraded.dragApproxUsd, legacy.dragApproxUsd, "upgraded drag should be lower");
        assertEq(routeSelection.amountIn, upgraded.amountIn, "quoted amountIn mismatch");
        assertEq(routeSelection.selectedRouteId, ROUTE_V4_SINGLE_HOP, "historical best route should be V4");
        assertGt(routeSelection.v4QuotedOut, routeSelection.v3QuotedOut, "V4 quote should be better onchain");
    }

    // Where is the drag?
    function testForkHistorical_rebalanceDiagnostic_BreaksOutFeeVsExecutionCost() public {
        RebalanceDragMetrics memory legacy = _runHistoricalRebalanceScenario(false);
        RebalanceDragMetrics memory upgraded = _runHistoricalRebalanceScenario(true);

        SwapDragBreakdown memory legacyBreakdown = _buildDragBreakdown(legacy, pool.fee());
        SwapDragBreakdown memory upgradedBreakdown = _buildDragBreakdown(upgraded, SWAP_V4_POOL_FEE);

        console2.log("legacy total drag in USD approx (6 decimals):", legacyBreakdown.totalDragApproxUsd); // 4_407_356
        console2.log("legacy fee-only drag in USD approx (6 decimals):", legacyBreakdown.feeCostApproxUsd); // 952_556
        console2.log("legacy non-fee drag in USD approx (6 decimals):", legacyBreakdown.nonFeeCostApproxUsd); // 3_454_800
        console2.log("upgraded total drag in USD approx (6 decimals):", upgradedBreakdown.totalDragApproxUsd); // 4_284_690 The total drag is less
        console2.log("upgraded fee-only drag in USD approx (6 decimals):", upgradedBreakdown.feeCostApproxUsd); // 76_204 The fee cost is less
        console2.log("upgraded non-fee drag in USD approx (6 decimals):", upgradedBreakdown.nonFeeCostApproxUsd); // 4_208_486 The non-fee cost is more

        assertGt(legacyBreakdown.totalDragApproxUsd, 0, "legacy total drag is zero");
        assertGt(upgradedBreakdown.totalDragApproxUsd, 0, "upgraded total drag is zero");
        assertLt(
            upgradedBreakdown.feeCostApproxUsd, legacyBreakdown.feeCostApproxUsd, "upgraded fee cost should be lower"
        );
        assertGt(legacyBreakdown.nonFeeCostApproxUsd, legacyBreakdown.feeCostApproxUsd, "legacy drag is mostly non-fee");
        assertGt(
            upgradedBreakdown.nonFeeCostApproxUsd, upgradedBreakdown.feeCostApproxUsd, "upgraded drag is mostly non-fee"
        );
    }

    function testForkHistorical_rebalanceDiagnostic_MapsDragCurveAcrossTargetRatios() public {
        uint16[5] memory targetRatiosBps =
            [uint16(1_000), uint16(3_000), uint16(HISTORICAL_OTHER_RATIO_BPS), uint16(7_000), uint16(8_500)];
        address baselineTokenIn;
        uint256 minAmountIn = type(uint256).max;
        uint256 maxAmountIn;

        for (uint256 i; i < targetRatiosBps.length; ++i) {
            RebalanceDragMetrics memory legacy = _runHistoricalRebalanceScenario(false, targetRatiosBps[i]);
            RebalanceDragMetrics memory upgraded = _runHistoricalRebalanceScenario(true, targetRatiosBps[i]);
            SwapDragBreakdown memory legacyBreakdown = _buildDragBreakdown(legacy, pool.fee());
            SwapDragBreakdown memory upgradedBreakdown = _buildDragBreakdown(upgraded, SWAP_V4_POOL_FEE);

            if (i == 0) baselineTokenIn = legacy.tokenIn;

            assertEq(legacy.tokenIn, upgraded.tokenIn, "curve direction mismatch");
            assertEq(legacy.tokenOut, upgraded.tokenOut, "curve output token mismatch");
            assertEq(legacy.amountIn, upgraded.amountIn, "curve amountIn mismatch");
            assertEq(legacy.tokenIn, baselineTokenIn, "curve direction changed");

            if (legacy.amountIn < minAmountIn) minAmountIn = legacy.amountIn;
            if (legacy.amountIn > maxAmountIn) maxAmountIn = legacy.amountIn;

            console2.log("curve targetOtherRatioBps:", targetRatiosBps[i]);
            console2.log("curve amountIn:", legacy.amountIn);
            console2.log("curve legacy total drag:", legacyBreakdown.totalDragApproxUsd);
            console2.log("curve legacy fee-only:", legacyBreakdown.feeCostApproxUsd);
            console2.log("curve legacy non-fee:", legacyBreakdown.nonFeeCostApproxUsd);
            console2.log("curve upgraded total drag:", upgradedBreakdown.totalDragApproxUsd);
            console2.log("curve upgraded fee-only:", upgradedBreakdown.feeCostApproxUsd);
            console2.log("curve upgraded non-fee:", upgradedBreakdown.nonFeeCostApproxUsd);
            /*
            curve targetOtherRatioBps: 1000
            curve amountIn: 18_029_457_954
            curve legacy total drag: 8_354_270
            curve upgraded total drag: 8_128_065
            ====================================
            curve targetOtherRatioBps: 3000
            curve amountIn: 14_022_911_743
            curve legacy total drag: 6_493_270
            curve upgraded total drag: 6_315_144
            ====================================
            curve targetOtherRatioBps: 5245
            curve amountIn: 9_525_563_619
            curve legacy total drag: 4_407_356
            curve upgraded total drag: 4_284_690
            ====================================
            curve targetOtherRatioBps: 7000
            curve amountIn: 6_009_819_318
            curve legacy total drag: 2_778_975
            curve upgraded total drag: 2_700_761
            ====================================
            curve targetOtherRatioBps: 8500
            curve amountIn: 3_004_909_659
            curve legacy total drag: 1_388_765
            curve upgraded total drag: 1_349_307
                      */
        }

        assertGt(maxAmountIn, minAmountIn, "curve samples did not change swap size");
    }

    function testForkHistorical_rebalanceDiagnostic_OptionGuardrails_PreAndPostUpgrade() public {
        StrategyGuardrailScenario[4] memory scenarios = [
            StrategyGuardrailScenario({twapWindow: 600, swapSlippageBps: 20}),
            StrategyGuardrailScenario({twapWindow: 300, swapSlippageBps: 30}),
            StrategyGuardrailScenario({twapWindow: 0, swapSlippageBps: 40}),
            StrategyGuardrailScenario({twapWindow: 60, swapSlippageBps: 40})
        ];

        for (uint256 i; i < scenarios.length; ++i) {
            RebalanceDragMetrics memory legacy = _runHistoricalRebalanceScenarioWithConfig(
                false, HISTORICAL_OTHER_RATIO_BPS, scenarios[i].twapWindow, scenarios[i].swapSlippageBps
            );
            RebalanceDragMetrics memory upgraded = _runHistoricalRebalanceScenarioWithConfig(
                true, HISTORICAL_OTHER_RATIO_BPS, scenarios[i].twapWindow, scenarios[i].swapSlippageBps
            );

            console2.log("guardrail twapWindow:", scenarios[i].twapWindow);
            console2.log("guardrail swapSlippageBps:", scenarios[i].swapSlippageBps);
            console2.log("guardrail legacy drag:", legacy.dragApproxUsd);
            console2.log("guardrail upgraded drag:", upgraded.dragApproxUsd);

            /*
            twapWindow: 600
            swapSlippageBps: 20
            legacy drag: 4_407_356
            upgraded drag: 4_284_690
            ====================================
            twapWindow: 300
            swapSlippageBps: 30
            legacy drag: 4_407_356
            upgraded drag: 4_284_690
            ====================================
            twapWindow: 0
            swapSlippageBps: 40
            legacy drag: 4_407_356
            upgraded drag: 4_284_690
            ====================================
            twapWindow: 60
            swapSlippageBps: 40
            legacy drag: 4_407_356
            upgraded drag: 4_284_690
                      */

            assertEq(legacy.amountIn, upgraded.amountIn, "guardrail amountIn mismatch");
            assertLt(upgraded.dragApproxUsd, legacy.dragApproxUsd, "guardrail V4 drag should be lower");
        }
    }

    function testForkHistorical_rebalanceDiagnostic_MapsDragAcrossTickRanges() public {
        TickRangeScenario[5] memory scenarios = [
            TickRangeScenario({lowerOffset: -3, upperOffset: 3}),
            TickRangeScenario({lowerOffset: -3, upperOffset: 4}),
            TickRangeScenario({lowerOffset: -4, upperOffset: 4}),
            TickRangeScenario({lowerOffset: -4, upperOffset: 5}),
            TickRangeScenario({lowerOffset: -5, upperOffset: 5})
        ];

        _selectFork(HISTORICAL_BLOCK);
        int24 spotTick = _spotTick();
        TickRangeBaseline memory baseline;

        for (uint256 i; i < scenarios.length; ++i) {
            baseline = _runAndAssertTickRangeScenario(spotTick, scenarios[i], baseline, i == 0);
        }
        /*
        range lowerOffset: -3
        range upperOffset: 3
        new lower tick: 0
        new upper tick: 6
        range amountIn: 9_525_563_619 -> same accross all ranges
        range legacy total drag: 4_407_356
        range legacy fee-only: 952_556
        range legacy non-fee: 3_454_800
        range upgraded total drag: 4_284_690
        range upgraded fee-only: 76_204
        range upgraded non-fee: 4_208_486
        ====================================
        range lowerOffset: -3
        range upperOffset: 4
        new lower tick: 0
        new upper tick: 7
        range amountIn: 9_525_563_619
        range legacy total drag: 4_407_356
        range legacy fee-only: 952_556
        range legacy non-fee: 3_454_800
        range upgraded total drag: 4_284_690
        range upgraded fee-only: 76_204
        range upgraded non-fee: 4_208_486
        ====================================
        range lowerOffset: -4
        range upperOffset: 4
        new lower tick: -1
        new upper tick: 7
        range amountIn: 9_525_563_619
        range legacy total drag: 4_407_356
        range legacy fee-only: 952_556
        range legacy non-fee: 3_454_800
        range upgraded total drag: 4_284_690
        range upgraded fee-only: 76_204
        range upgraded non-fee: 4_208_486
        ====================================
        range lowerOffset: -4
        range upperOffset: 5
        new lower tick: -1
        new upper tick: 8
        range amountIn: 9_525_563_619
        range legacy total drag: 4_407_356
        range legacy fee-only: 952_556
        range legacy non-fee: 3_454_800
        range upgraded total drag: 4_284_690
        range upgraded fee-only: 76_204
        range upgraded non-fee: 4_208_486
        ====================================
        range lowerOffset: -5
        range upperOffset: 5
        new lower tick: -2
        new upper tick: 8
        range amountIn: 9_525_563_619
        range legacy total drag: 4_407_356
        range legacy fee-only: 952_556
        range legacy non-fee: 3_454_800
        range upgraded total drag: 4_284_690
        range upgraded fee-only: 76_204
        range upgraded non-fee: 4_208_486
              */

        assertGt(baseline.amountIn, 0, "baseline amountIn is zero");
    }

    function _runHistoricalRebalanceScenario(bool upgradeToV4) internal returns (RebalanceDragMetrics memory metrics_) {
        return _runHistoricalRebalanceScenario(upgradeToV4, HISTORICAL_OTHER_RATIO_BPS);
    }

    function _runHistoricalRebalanceScenario(bool upgradeToV4, uint16 otherRatioBps)
        internal
        returns (RebalanceDragMetrics memory metrics_)
    {
        return _runHistoricalRebalanceScenarioWithConfig(upgradeToV4, otherRatioBps, 1800, 100);
    }

    function _runHistoricalRebalanceScenarioWithConfig(
        bool upgradeToV4,
        uint16 otherRatioBps,
        uint32 twapWindow,
        uint16 swapSlippageBps
    ) internal returns (RebalanceDragMetrics memory metrics_) {
        return _runHistoricalRebalanceScenarioWithRangeConfig(
            upgradeToV4,
            otherRatioBps,
            HISTORICAL_NEW_TICK_LOWER,
            HISTORICAL_NEW_TICK_UPPER,
            twapWindow,
            swapSlippageBps
        );
    }

    function _runHistoricalRebalanceScenarioWithRangeConfig(
        bool upgradeToV4,
        uint16 otherRatioBps,
        int24 newTickLower,
        int24 newTickUpper,
        uint32 twapWindow,
        uint16 swapSlippageBps
    ) internal returns (RebalanceDragMetrics memory metrics_) {
        _selectFork(HISTORICAL_BLOCK);

        _approveNFTForStrategy();

        metrics_.oldTickLower = uniV3.tickLower();
        metrics_.oldTickUpper = uniV3.tickUpper();
        metrics_.spotTickBefore = _spotTick();

        require(
            metrics_.spotTickBefore < metrics_.oldTickLower || metrics_.spotTickBefore >= metrics_.oldTickUpper,
            "position not out of range"
        );

        metrics_.newTickLower = newTickLower;
        metrics_.newTickUpper = newTickUpper;

        if (upgradeToV4) {
            _upgradeStrategyToLocalV4Implementation();
        }

        _configureStrategyGuardrails(twapWindow, swapSlippageBps);

        bytes memory rebalancePayload =
            _buildRebalancePayload(upgradeToV4, metrics_.newTickLower, metrics_.newTickUpper, otherRatioBps);

        vm.recordLogs();
        vm.prank(operator);
        aggregator.rebalance(_perStrategyData(rebalancePayload));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (metrics_.tokenIn, metrics_.tokenOut, metrics_.amountIn, metrics_.amountOut) = _extractSwapExecutedLog(logs);
        metrics_.dragApproxUsd = _computeStableUsdDragApprox(metrics_.amountIn, metrics_.amountOut);
        if (upgradeToV4) lastRouteSelectionMetrics = _extractRouteSelectionLogs(logs);
        else delete lastRouteSelectionMetrics;

        assertGt(uniV3.positionTokenId(), 0, "rebalance did not mint a new position");
    }

    function _runAndAssertTickRangeScenario(
        int24 spotTick,
        TickRangeScenario memory scenario,
        TickRangeBaseline memory baseline,
        bool isBaseline
    ) internal returns (TickRangeBaseline memory baseline_) {
        baseline_ = baseline;

        int24 newTickLower = spotTick + scenario.lowerOffset;
        int24 newTickUpper = spotTick + scenario.upperOffset;

        RebalanceDragMetrics memory legacy = _runHistoricalRebalanceScenarioWithRangeConfig(
            false, HISTORICAL_OTHER_RATIO_BPS, newTickLower, newTickUpper, 1800, 100
        );
        RebalanceDragMetrics memory upgraded = _runHistoricalRebalanceScenarioWithRangeConfig(
            true, HISTORICAL_OTHER_RATIO_BPS, newTickLower, newTickUpper, 1800, 100
        );
        RouteSelectionMetrics memory routeSelection = lastRouteSelectionMetrics;
        SwapDragBreakdown memory legacyBreakdown = _buildDragBreakdown(legacy, pool.fee());
        SwapDragBreakdown memory upgradedBreakdown = _buildDragBreakdown(upgraded, SWAP_V4_POOL_FEE);

        _assertTickRangeScenarioPair(spotTick, newTickLower, newTickUpper, legacy, upgraded);
        baseline_ = _captureOrAssertTickRangeBaseline(
            baseline_, legacy, upgraded, routeSelection, legacyBreakdown, upgradedBreakdown, isBaseline
        );
        _logTickRangeScenario(
            scenario, newTickLower, newTickUpper, legacy, routeSelection, legacyBreakdown, upgradedBreakdown
        );
    }

    function _assertTickRangeScenarioPair(
        int24 spotTick,
        int24 newTickLower,
        int24 newTickUpper,
        RebalanceDragMetrics memory legacy,
        RebalanceDragMetrics memory upgraded
    ) internal pure {
        assertEq(legacy.newTickLower, newTickLower, "range lower tick mismatch");
        assertEq(legacy.newTickUpper, newTickUpper, "range upper tick mismatch");
        assertEq(upgraded.newTickLower, newTickLower, "upgraded range lower tick mismatch");
        assertEq(upgraded.newTickUpper, newTickUpper, "upgraded range upper tick mismatch");
        assertEq(legacy.spotTickBefore, spotTick, "legacy spot tick mismatch");
        assertEq(upgraded.spotTickBefore, spotTick, "upgraded spot tick mismatch");
        assertEq(legacy.tokenIn, upgraded.tokenIn, "range direction mismatch");
        assertEq(legacy.tokenOut, upgraded.tokenOut, "range output token mismatch");
        assertEq(legacy.amountIn, upgraded.amountIn, "range amountIn mismatch");
        assertGt(legacy.amountIn, 0, "range amountIn is zero");
        assertGt(legacy.amountOut, 0, "legacy range amountOut is zero");
        assertGt(upgraded.amountOut, 0, "upgraded range amountOut is zero");
    }

    function _captureOrAssertTickRangeBaseline(
        TickRangeBaseline memory baseline,
        RebalanceDragMetrics memory legacy,
        RebalanceDragMetrics memory upgraded,
        RouteSelectionMetrics memory routeSelection,
        SwapDragBreakdown memory legacyBreakdown,
        SwapDragBreakdown memory upgradedBreakdown,
        bool isBaseline
    ) internal pure returns (TickRangeBaseline memory baseline_) {
        baseline_ = baseline;

        if (isBaseline) {
            baseline_.amountIn = legacy.amountIn;
            baseline_.legacyAmountOut = legacy.amountOut;
            baseline_.upgradedAmountOut = upgraded.amountOut;
            baseline_.legacyDrag = legacyBreakdown.totalDragApproxUsd;
            baseline_.upgradedDrag = upgradedBreakdown.totalDragApproxUsd;
            baseline_.v3QuotedOut = routeSelection.v3QuotedOut;
            baseline_.v4QuotedOut = routeSelection.v4QuotedOut;
            baseline_.selectedRouteId = routeSelection.selectedRouteId;
            return baseline_;
        }

        // Under the current rebalance implementation, swaps happen before reminting the new range.
        // That means changing the target ticks alone does not change the background swap sizing.
        assertEq(legacy.amountIn, baseline_.amountIn, "tick range changed legacy swap size");
        assertEq(legacy.amountOut, baseline_.legacyAmountOut, "tick range changed legacy swap output");
        assertEq(upgraded.amountOut, baseline_.upgradedAmountOut, "tick range changed upgraded swap output");
        assertEq(legacyBreakdown.totalDragApproxUsd, baseline_.legacyDrag, "tick range changed legacy drag");
        assertEq(upgradedBreakdown.totalDragApproxUsd, baseline_.upgradedDrag, "tick range changed upgraded drag");
        assertEq(routeSelection.v3QuotedOut, baseline_.v3QuotedOut, "tick range changed v3 quote");
        assertEq(routeSelection.v4QuotedOut, baseline_.v4QuotedOut, "tick range changed v4 quote");
        assertEq(routeSelection.selectedRouteId, baseline_.selectedRouteId, "tick range changed best route");
    }

    function _logTickRangeScenario(
        TickRangeScenario memory scenario,
        int24 newTickLower,
        int24 newTickUpper,
        RebalanceDragMetrics memory legacy,
        RouteSelectionMetrics memory routeSelection,
        SwapDragBreakdown memory legacyBreakdown,
        SwapDragBreakdown memory upgradedBreakdown
    ) internal pure {
        console2.log("range lowerOffset:", scenario.lowerOffset);
        console2.log("range upperOffset:", scenario.upperOffset);
        console2.logInt(newTickLower);
        console2.logInt(newTickUpper);
        console2.log("range amountIn:", legacy.amountIn);
        console2.log("range legacy total drag:", legacyBreakdown.totalDragApproxUsd);
        console2.log("range legacy fee-only:", legacyBreakdown.feeCostApproxUsd);
        console2.log("range legacy non-fee:", legacyBreakdown.nonFeeCostApproxUsd);
        console2.log("range upgraded total drag:", upgradedBreakdown.totalDragApproxUsd);
        console2.log("range upgraded fee-only:", upgradedBreakdown.feeCostApproxUsd);
        console2.log("range upgraded non-fee:", upgradedBreakdown.nonFeeCostApproxUsd);
        console2.log("range selected route id:", routeSelection.selectedRouteId);
        console2.log("range quoted v3 amountOut:", routeSelection.v3QuotedOut);
        console2.log("range quoted v4 amountOut:", routeSelection.v4QuotedOut);
    }

    function _selectFork(uint256 blockNumber) internal {
        uint256 forkId = vm.createFork(vm.envString("ARBITRUM_MAINNET_RPC_URL"), blockNumber);
        vm.selectFork(forkId);
        addrGetter = new ForkAddressGetter();
        _loadForkContracts();
    }

    function _loadForkContracts() internal {
        addrMgr = AddressManager(_getAddr("AddressManager"));
        vault = SFVault(_getAddr("SFVault"));
        aggregator = SFStrategyAggregator(_getAddr("SFStrategyAggregator"));
        uniV3 = SFUniswapV3Strategy(_getAddr("SFUniswapV3Strategy"));
        underlying = IERC20(vault.asset());
        otherToken = uniV3.otherToken();
        pool = uniV3.pool();

        operator = addrMgr.currentRoleHolders(Roles.OPERATOR);
        pauseGuardian = addrMgr.currentRoleHolders(Roles.PAUSE_GUARDIAN);

        require(operator != address(0) && addrMgr.hasRole(Roles.OPERATOR, operator), "operator missing");
        _ensureUnpaused();
    }

    function _ensureUnpaused() internal {
        if (pauseGuardian == address(0) || !addrMgr.hasRole(Roles.PAUSE_GUARDIAN, pauseGuardian)) return;

        if (vault.paused()) {
            vm.prank(pauseGuardian);
            vault.unpause();
        }

        if (aggregator.paused()) {
            vm.prank(pauseGuardian);
            aggregator.unpause();
        }

        if (uniV3.paused()) {
            vm.prank(pauseGuardian);
            uniV3.unpause();
        }
    }

    function _approveNFTForStrategy() internal {
        vm.prank(address(vault));
        IERC721(NONFUNGIBLE_POSITION_MANAGER).setApprovalForAll(address(uniV3), true);
    }

    function _upgradeStrategyToLocalV4Implementation() internal {
        address helper = address(new SFUniswapV3SwapRouterHelper(address(addrMgr)));

        _upsertSwapRouterHelper(helper);

        vm.startPrank(operator);
        uniV3.upgradeToAndCall(address(new SFUniswapV3Strategy()), "");
        uniV3.setSwapV4PoolConfig(SWAP_V4_POOL_FEE, SWAP_V4_POOL_TICK_SPACING, SWAP_V4_POOL_HOOKS);
        vm.stopPrank();
    }

    function _upsertSwapRouterHelper(address helper) internal {
        address owner = addrMgr.owner();

        vm.prank(owner);
        try addrMgr.updateProtocolAddress(SWAP_ROUTER_HELPER_NAME, helper) {
            return;
        } catch {}

        vm.prank(owner);
        addrMgr.addProtocolAddress(SWAP_ROUTER_HELPER_NAME, helper, ProtocolAddressType.Helper);
    }

    function _configureStrategyGuardrails(uint32 twapWindow, uint16 swapSlippageBps) internal {
        vm.startPrank(operator);
        uniV3.setTwapWindow(twapWindow);
        uniV3.setSwapSlippageBPS(swapSlippageBps);
        vm.stopPrank();

        assertEq(uniV3.twapWindow(), twapWindow, "twapWindow not applied");
        assertEq(uniV3.swapSlippageBPS(), swapSlippageBps, "swapSlippageBPS not applied");
    }

    function _buildRebalancePayload(bool useV4Swap, int24 newTickLower, int24 newTickUpper, uint16 otherRatioBps)
        internal
        view
        returns (bytes memory)
    {
        bytes memory swapToOtherData;
        bytes memory swapToUnderlyingData;

        if (useV4Swap) {
            swapToOtherData = _encodeRankedSwapDataExactInBps(
                MAX_BPS, HISTORICAL_SWAP_DEADLINE, ROUTE_V4_SINGLE_HOP, ROUTE_V3_SINGLE_HOP
            );
            swapToUnderlyingData = _encodeRankedSwapDataExactInBps(
                MAX_BPS, HISTORICAL_SWAP_DEADLINE, ROUTE_V4_SINGLE_HOP, ROUTE_V3_SINGLE_HOP
            );
        } else {
            uint24 poolFee = pool.fee();
            swapToOtherData = _encodeLegacyV3SwapDataExactInBps(
                address(underlying), address(otherToken), poolFee, HISTORICAL_SWAP_DEADLINE
            );
            swapToUnderlyingData = _encodeLegacyV3SwapDataExactInBps(
                address(otherToken), address(underlying), poolFee, HISTORICAL_SWAP_DEADLINE
            );
        }

        bytes memory actionData =
            abi.encode(otherRatioBps, swapToOtherData, swapToUnderlyingData, HISTORICAL_PM_DEADLINE, 0, 0);
        return abi.encode(newTickLower, newTickUpper, actionData);
    }

    function _encodeRankedSwapDataExactInBps(uint16 amountInBps, uint256 deadline, uint8 route0, uint8 route1)
        internal
        pure
        returns (bytes memory)
    {
        require(amountInBps <= MAX_BPS, "amountInBps>MAX_BPS");
        uint8[2] memory routeIds;
        uint256[2] memory amountOutMins;
        routeIds[0] = route0;
        routeIds[1] = route1;
        return abi.encode(AMOUNT_IN_BPS_FLAG | uint256(amountInBps), deadline, uint8(2), routeIds, amountOutMins);
    }

    function _encodeLegacyV3SwapDataExactInBps(address tokenIn, address tokenOut, uint24 fee, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(uniV3),
            AMOUNT_IN_BPS_FLAG | uint256(MAX_BPS),
            uint256(0),
            abi.encodePacked(tokenIn, fee, tokenOut),
            true
        );
        return abi.encode(inputs, deadline);
    }

    function _extractSwapExecutedLog(Vm.Log[] memory logs)
        internal
        view
        returns (address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 amountOut_)
    {
        uint256 matches;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(uniV3) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != ON_SWAP_EXECUTED_SIG) continue;

            tokenIn_ = address(uint160(uint256(logs[i].topics[1])));
            tokenOut_ = address(uint160(uint256(logs[i].topics[2])));
            (amountIn_, amountOut_) = abi.decode(logs[i].data, (uint256, uint256));
            ++matches;
        }

        require(matches == 1, "expected exactly one swap");
    }

    function _extractRouteSelectionLogs(Vm.Log[] memory logs)
        internal
        view
        returns (RouteSelectionMetrics memory metrics_)
    {
        uint256 comparedMatches;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(uniV3) || logs[i].topics.length == 0) continue;

            if (logs[i].topics[0] == ON_SWAP_ROUTES_COMPARED_SIG) {
                (metrics_.amountIn, metrics_.v3QuotedOut, metrics_.v4QuotedOut, metrics_.selectedRouteId) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint8));
                ++comparedMatches;
            }
        }

        require(comparedMatches == 1, "expected exactly one route comparison");
    }

    function _computeStableUsdDragApprox(uint256 amountIn, uint256 amountOut) internal pure returns (uint256) {
        return amountIn >= amountOut ? amountIn - amountOut : amountOut - amountIn;
    }

    function _buildDragBreakdown(RebalanceDragMetrics memory metrics_, uint24 feePips)
        internal
        pure
        returns (SwapDragBreakdown memory breakdown_)
    {
        breakdown_.feePips = feePips;
        breakdown_.totalDragApproxUsd = metrics_.dragApproxUsd;
        breakdown_.feeCostApproxUsd = _computeFeeCostApproxUsd(metrics_.amountIn, feePips);
        breakdown_.nonFeeCostApproxUsd = breakdown_.totalDragApproxUsd > breakdown_.feeCostApproxUsd
            ? breakdown_.totalDragApproxUsd - breakdown_.feeCostApproxUsd
            : 0;
    }

    function _computeFeeCostApproxUsd(uint256 amountIn, uint24 feePips) internal pure returns (uint256) {
        return (amountIn * uint256(feePips)) / 1_000_000;
    }

    function _spotTick() internal view returns (int24 tick_) {
        (, tick_,,,,,) = pool.slot0();
    }

    function _perStrategyData(bytes memory childData) internal view returns (bytes memory) {
        address[] memory strategies = new address[](1);
        bytes[] memory payloads = new bytes[](1);
        strategies[0] = address(uniV3);
        payloads[0] = childData;
        return abi.encode(strategies, payloads);
    }

    function _getAddr(string memory contractName) internal view returns (address) {
        return addrGetter.getAddress(block.chainid, contractName);
    }
}

contract ForkAddressGetter is GetContractAddress {
    function getAddress(uint256 chainId, string memory contractName) external view returns (address) {
        return _getContractAddress(chainId, contractName);
    }
}
