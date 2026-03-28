// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {SFVault} from "contracts/saveFunds/protocol/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/protocol/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/protocol/SFUniswapV3Strategy.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

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

    uint256 internal constant HISTORICAL_BLOCK = 446153833;
    int24 internal constant HISTORICAL_NEW_TICK_LOWER = 1;
    int24 internal constant HISTORICAL_NEW_TICK_UPPER = 6;
    uint16 internal constant HISTORICAL_OTHER_RATIO_BPS = 5_245;
    uint256 internal constant HISTORICAL_PM_DEADLINE = 1_774_606_087;
    uint256 internal constant HISTORICAL_SWAP_DEADLINE = 0;
    uint16 internal constant MAX_BPS = 10_000;
    uint256 internal constant AMOUNT_IN_BPS_FLAG = uint256(1) << 255;
    bytes32 internal constant ON_SWAP_EXECUTED_SIG =
        keccak256("OnSwapExecuted(address,address,uint256,uint256)");
    address internal constant NONFUNGIBLE_POSITION_MANAGER =
        0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
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

    address internal operator;
    address internal pauseGuardian;

    function setUp() public {}

    function testForkHistorical_rebalanceLegacyPath_CharacterizesSwapDrag() public {
        RebalanceDragMetrics memory legacy = _runHistoricalRebalanceScenario(false);

        console2.log("legacy drag in USD approx (6 decimals):", legacy.dragApproxUsd);
        console2.log("legacy amountIn:", legacy.amountIn);
        console2.log("legacy amountOut:", legacy.amountOut);
        console2.logInt(legacy.spotTickBefore);

        assertGt(legacy.amountIn, 0, "legacy swap amountIn is zero");
        assertGt(legacy.amountOut, 0, "legacy swap amountOut is zero");
        assertGt(legacy.dragApproxUsd, 0, "legacy drag should be positive");
        assertGt(legacy.dragApproxUsd, 4_000_000, "legacy drag should be meaningful");
        assertLt(legacy.dragApproxUsd, 5_000_000, "legacy drag moved away from the historical range");
    }

    function testForkHistorical_rebalanceV4Path_ReducesSwapDrag() public {
        RebalanceDragMetrics memory legacy = _runHistoricalRebalanceScenario(false);
        RebalanceDragMetrics memory upgraded = _runHistoricalRebalanceScenario(true);

        console2.log("legacy drag in USD approx (6 decimals):", legacy.dragApproxUsd);
        console2.log("v4 drag in USD approx (6 decimals):", upgraded.dragApproxUsd);
        console2.log("legacy amountIn:", legacy.amountIn);
        console2.log("v4 amountIn:", upgraded.amountIn);
        console2.log("legacy amountOut:", legacy.amountOut);
        console2.log("v4 amountOut:", upgraded.amountOut);

        assertEq(upgraded.oldTickLower, legacy.oldTickLower, "old lower tick mismatch");
        assertEq(upgraded.oldTickUpper, legacy.oldTickUpper, "old upper tick mismatch");
        assertEq(upgraded.newTickLower, legacy.newTickLower, "new lower tick mismatch");
        assertEq(upgraded.newTickUpper, legacy.newTickUpper, "new upper tick mismatch");
        assertEq(upgraded.spotTickBefore, legacy.spotTickBefore, "spot tick mismatch");

        assertGt(legacy.dragApproxUsd, 0, "legacy drag should be positive");
        assertGt(upgraded.amountIn, 0, "upgraded swap amountIn is zero");
        assertGt(upgraded.amountOut, 0, "upgraded swap amountOut is zero");
        assertLt(upgraded.dragApproxUsd, legacy.dragApproxUsd, "V4 swap drag should be lower");
    }

    function testForkHistorical_rebalanceDiagnostic_BreaksOutFeeVsExecutionCost() public {
        RebalanceDragMetrics memory legacy = _runHistoricalRebalanceScenario(false);
        RebalanceDragMetrics memory upgraded = _runHistoricalRebalanceScenario(true);

        SwapDragBreakdown memory legacyBreakdown = _buildDragBreakdown(legacy, pool.fee());
        SwapDragBreakdown memory upgradedBreakdown = _buildDragBreakdown(upgraded, SWAP_V4_POOL_FEE);

        console2.log("legacy total drag in USD approx (6 decimals):", legacyBreakdown.totalDragApproxUsd);
        console2.log("legacy fee-only drag in USD approx (6 decimals):", legacyBreakdown.feeCostApproxUsd);
        console2.log(
            "legacy non-fee drag in USD approx (6 decimals):", legacyBreakdown.nonFeeCostApproxUsd
        );
        console2.log("v4 total drag in USD approx (6 decimals):", upgradedBreakdown.totalDragApproxUsd);
        console2.log("v4 fee-only drag in USD approx (6 decimals):", upgradedBreakdown.feeCostApproxUsd);
        console2.log(
            "v4 non-fee drag in USD approx (6 decimals):", upgradedBreakdown.nonFeeCostApproxUsd
        );

        assertGt(legacyBreakdown.totalDragApproxUsd, 0, "legacy total drag is zero");
        assertGt(upgradedBreakdown.totalDragApproxUsd, 0, "v4 total drag is zero");
        assertLt(upgradedBreakdown.feeCostApproxUsd, legacyBreakdown.feeCostApproxUsd, "V4 fee cost should be lower");
        assertGt(
            legacyBreakdown.nonFeeCostApproxUsd, legacyBreakdown.feeCostApproxUsd, "legacy drag is mostly non-fee"
        );
        assertGt(
            upgradedBreakdown.nonFeeCostApproxUsd, upgradedBreakdown.feeCostApproxUsd, "v4 drag is mostly non-fee"
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
            console2.log("curve v4 total drag:", upgradedBreakdown.totalDragApproxUsd);
            console2.log("curve v4 fee-only:", upgradedBreakdown.feeCostApproxUsd);
            console2.log("curve v4 non-fee:", upgradedBreakdown.nonFeeCostApproxUsd);
        }

        assertGt(maxAmountIn, minAmountIn, "curve samples did not change swap size");
    }

    function _runHistoricalRebalanceScenario(bool upgradeToV4)
        internal
        returns (RebalanceDragMetrics memory metrics_)
    {
        return _runHistoricalRebalanceScenario(upgradeToV4, HISTORICAL_OTHER_RATIO_BPS);
    }

    function _runHistoricalRebalanceScenario(bool upgradeToV4, uint16 otherRatioBps)
        internal
        returns (RebalanceDragMetrics memory metrics_)
    {
        _selectFork(HISTORICAL_BLOCK);

        _approveNFTForStrategy();

        metrics_.oldTickLower = uniV3.tickLower();
        metrics_.oldTickUpper = uniV3.tickUpper();
        metrics_.spotTickBefore = _spotTick();

        require(
            metrics_.spotTickBefore < metrics_.oldTickLower || metrics_.spotTickBefore >= metrics_.oldTickUpper,
            "position not out of range"
        );

        metrics_.newTickLower = HISTORICAL_NEW_TICK_LOWER;
        metrics_.newTickUpper = HISTORICAL_NEW_TICK_UPPER;

        if (upgradeToV4) {
            _upgradeStrategyToLocalV4Implementation();
        }

        bytes memory rebalancePayload = _buildRebalancePayload(
            upgradeToV4, metrics_.newTickLower, metrics_.newTickUpper, otherRatioBps
        );

        vm.recordLogs();
        vm.prank(operator);
        aggregator.rebalance(_perStrategyData(rebalancePayload));

        (metrics_.tokenIn, metrics_.tokenOut, metrics_.amountIn, metrics_.amountOut) = _extractSwapExecutedLog();
        metrics_.dragApproxUsd = _computeStableUsdDragApprox(metrics_.amountIn, metrics_.amountOut);

        assertGt(uniV3.positionTokenId(), 0, "rebalance did not mint a new position");
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
        vm.startPrank(operator);
        uniV3.upgradeToAndCall(address(new SFUniswapV3Strategy()), "");
        uniV3.setSwapV4PoolConfig(SWAP_V4_POOL_FEE, SWAP_V4_POOL_TICK_SPACING, SWAP_V4_POOL_HOOKS);
        vm.stopPrank();
    }

    function _buildRebalancePayload(bool useV4Swap, int24 newTickLower, int24 newTickUpper, uint16 otherRatioBps)
        internal
        view
        returns (bytes memory)
    {
        bytes memory swapToOtherData;
        bytes memory swapToUnderlyingData;

        if (useV4Swap) {
            swapToOtherData = _encodeCompactSwapDataExactInBps(MAX_BPS, HISTORICAL_SWAP_DEADLINE);
            swapToUnderlyingData = _encodeCompactSwapDataExactInBps(MAX_BPS, HISTORICAL_SWAP_DEADLINE);
        } else {
            uint24 poolFee = pool.fee();
            swapToOtherData = _encodeLegacyV3SwapDataExactInBps(
                address(underlying), address(otherToken), poolFee, HISTORICAL_SWAP_DEADLINE
            );
            swapToUnderlyingData =
                _encodeLegacyV3SwapDataExactInBps(
                    address(otherToken), address(underlying), poolFee, HISTORICAL_SWAP_DEADLINE
                );
        }

        bytes memory actionData = abi.encode(
            otherRatioBps, swapToOtherData, swapToUnderlyingData, HISTORICAL_PM_DEADLINE, 0, 0
        );
        return abi.encode(newTickLower, newTickUpper, actionData);
    }

    function _encodeCompactSwapDataExactInBps(uint16 amountInBps, uint256 deadline)
        internal
        pure
        returns (bytes memory)
    {
        require(amountInBps <= MAX_BPS, "amountInBps>MAX_BPS");
        return abi.encode(AMOUNT_IN_BPS_FLAG | uint256(amountInBps), uint256(0), deadline);
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

    function _extractSwapExecutedLog()
        internal
        returns (address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 amountOut_)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
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
