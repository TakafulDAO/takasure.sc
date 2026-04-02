// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {SFVault} from "contracts/saveFunds/protocol/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/protocol/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/protocol/SFUniswapV3Strategy.sol";
import {
    SaveFundsInvestAutomationRunner
} from "contracts/helpers/chainlink/automation/SaveFundsInvestAutomationRunner.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {LiquidityAmountsV3} from "contracts/helpers/uniswapHelpers/libraries/LiquidityAmountsV3.sol";
import {TickMathV3} from "contracts/helpers/uniswapHelpers/libraries/TickMathV3.sol";
import {PositionReader} from "contracts/helpers/uniswapHelpers/libraries/PositionReader.sol";
import {INonfungiblePositionManager} from "contracts/interfaces/helpers/INonfungiblePositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract SaveFundsInvestAutomationRunnerForkTest is Test {
    uint256 internal constant FORK_BLOCK = 430826360;
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant AMOUNT_IN_BPS_FLAG = 1 << 255;
    uint256 internal constant ARBITRUM_ONE_LAST_SUCCESSFUL_REBALANCE = 1_774_106_444;
    address internal constant UNI_V3_POSITION_MANAGER_ARBITRUM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    bytes32 internal constant ON_INVEST_SIG = keccak256("OnInvestIntoStrategy(uint256,uint256,bytes32)");
    bytes32 internal constant ON_UPKEEP_ATTEMPT_SIG = keccak256("OnUpkeepAttempt(uint256,uint256,uint16,bytes32)");
    bytes32 internal constant ON_INVEST_SUCCEEDED_SIG = keccak256("OnInvestSucceeded(uint256,uint256,uint256,uint16)");
    bytes32 internal constant ON_INVEST_FAILED_SIG = keccak256("OnInvestFailed(uint256,bytes)");
    bytes32 internal constant ON_UPKEEP_SKIPPED_PAUSED_SIG = keccak256("OnUpkeepSkippedPaused(uint256)");
    bytes32 internal constant ON_UPKEEP_SKIPPED_LOW_IDLE_SIG = keccak256("OnUpkeepSkippedLowIdle(uint256,uint256,uint256)");

    AddressGetter internal addrGetter;
    AddressManager internal addrMgr;
    SFVault internal vault;
    SFStrategyAggregator internal aggregator;
    SFUniswapV3Strategy internal uniV3;
    IERC20 internal asset;

    SaveFundsInvestAutomationRunner internal runner;

    address internal operator;
    address internal backendAdmin;
    address internal pauseGuardian;

    function setUp() public {
        uint256 forkId = vm.createFork(vm.envString("ARBITRUM_MAINNET_RPC_URL"), FORK_BLOCK);
        vm.selectFork(forkId);

        addrGetter = new AddressGetter();

        addrMgr = AddressManager(_getAddr("AddressManager"));
        vault = SFVault(_getAddr("SFVault"));
        aggregator = SFStrategyAggregator(_getAddr("SFStrategyAggregator"));
        uniV3 = SFUniswapV3Strategy(_getAddr("SFUniswapV3Strategy"));
        asset = IERC20(vault.asset());

        operator = addrMgr.currentRoleHolders(Roles.OPERATOR);
        backendAdmin = addrMgr.currentRoleHolders(Roles.BACKEND_ADMIN);
        pauseGuardian = addrMgr.currentRoleHolders(Roles.PAUSE_GUARDIAN);

        require(operator != address(0) && addrMgr.hasRole(Roles.OPERATOR, operator), "operator missing");

        _ensureBackendAdmin();
        _ensureUnpaused();

        // Remove cap so tests can always deposit.
        vm.prank(operator);
        vault.setTVLCap(0);

        address runnerImplementation = address(new SaveFundsInvestAutomationRunner());
        address runnerProxy = UnsafeUpgrades.deployUUPSProxy(
            runnerImplementation,
            abi.encodeCall(
                SaveFundsInvestAutomationRunner.initialize,
                (address(vault), address(aggregator), address(uniV3), address(addrMgr), 24 hours, 1, address(this))
            )
        );
        runner = SaveFundsInvestAutomationRunner(runnerProxy);
        runner.initializeV2();

        if (runner.strictUniOnlyAllocation()) runner.toggleStrictUniOnlyAllocation();
        if (runner.rebalanceEnabled()) runner.toggleRebalanceEnabled();
    }

    function testRunnerFork_acceptKeeperRole() public {
        _grantKeeperRoleToRunner();
        assertTrue(addrMgr.hasRole(Roles.KEEPER, address(runner)));
    }

    function testRunnerFork_initializeV2_SetsRebalanceDefaults() public {
        address runnerImplementation = address(new SaveFundsInvestAutomationRunner());
        address runnerProxy = UnsafeUpgrades.deployUUPSProxy(
            runnerImplementation,
            abi.encodeCall(
                SaveFundsInvestAutomationRunner.initialize,
                (address(vault), address(aggregator), address(uniV3), address(addrMgr), 24 hours, 1, address(this))
            )
        );
        SaveFundsInvestAutomationRunner upgradeRunner = SaveFundsInvestAutomationRunner(runnerProxy);

        assertEq(upgradeRunner.rebalanceCheckInterval(), 0);
        assertEq(upgradeRunner.lastRebalanceCheck(), 0);
        assertEq(upgradeRunner.lastSuccessfulRebalance(), 0);
        assertFalse(upgradeRunner.rebalanceEnabled());

        upgradeRunner.initializeV2();

        assertEq(upgradeRunner.rebalanceCheckInterval(), 6 hours);
        assertEq(upgradeRunner.lastRebalanceCheck(), block.timestamp - 6 hours);
        assertEq(upgradeRunner.lastSuccessfulRebalance(), ARBITRUM_ONE_LAST_SUCCESSFUL_REBALANCE);
        assertTrue(upgradeRunner.rebalanceEnabled());
    }

    function testRunnerFork_setInterval_BelowDaily_RevertsWhenTestModeDisabled() public {
        vm.expectRevert(SaveFundsInvestAutomationRunner.SaveFundsInvestAutomationRunner__TooSmall.selector);
        runner.setInterval(1 hours);
    }

    function testRunnerFork_setInterval_BelowDaily_AllowsWhenTestModeEnabled() public {
        if (!runner.testMode()) runner.toggleTestMode();
        runner.setInterval(1 hours);
        assertEq(runner.interval(), 1 hours);
    }

    function testRunnerFork_setRebalanceCheckInterval_BelowSixHours_RevertsWhenTestModeDisabled() public {
        vm.expectRevert(SaveFundsInvestAutomationRunner.SaveFundsInvestAutomationRunner__TooSmall.selector);
        runner.setRebalanceCheckInterval(1 hours);
    }

    function testRunnerFork_setRebalanceCheckInterval_SixHours_AllowsWhenTestModeDisabled() public {
        runner.setRebalanceCheckInterval(6 hours);
        assertEq(runner.rebalanceCheckInterval(), 6 hours);
    }

    function testRunnerFork_setRebalanceCheckInterval_BelowSixHours_AllowsWhenTestModeEnabled() public {
        if (!runner.testMode()) runner.toggleTestMode();
        runner.setRebalanceCheckInterval(1 hours);
        assertEq(runner.rebalanceCheckInterval(), 1 hours);
    }

    function testRunnerFork_setManualOtherRatioBPS_RevertsAboveMax() public {
        vm.expectRevert(SaveFundsInvestAutomationRunner.SaveFundsInvestAutomationRunner__OutOfRange.selector);
        runner.setManualOtherRatioBPS(uint16(MAX_BPS + 1));
    }

    function testRunnerFork_setSwapBPS_RevertsAboveMax() public {
        vm.expectRevert(SaveFundsInvestAutomationRunner.SaveFundsInvestAutomationRunner__OutOfRange.selector);
        runner.setSwapBPS(uint16(MAX_BPS + 1), 0);
    }

    function testRunnerFork_checkUpkeep_TrueAfterDepositAndInterval() public {
        _registerAndDeposit(makeAddr("member1"), 1_000e6);
        vm.warp(block.timestamp + runner.interval() + 1);

        (bool upkeepNeeded, bytes memory performData) = runner.checkUpkeep("");
        (uint256 idleFromData, bool investNeeded,) = abi.decode(performData, (uint256, bool, bool));

        assertTrue(upkeepNeeded);
        assertTrue(investNeeded);
        assertEq(idleFromData, vault.idleAssets());
    }

    function testRunnerFork_checkUpkeep_FalseWhenRunnerPaused() public {
        runner.pause();

        (bool upkeepNeeded, bytes memory performData) = runner.checkUpkeep("");
        uint256 lastRunBefore = runner.lastRun();

        runner.performUpkeep("");

        assertFalse(upkeepNeeded);
        assertEq(performData.length, 0);
        assertEq(runner.lastRun(), lastRunBefore);

        runner.unpause();
        assertFalse(runner.paused());
    }

    function testRunnerFork_checkUpkeep_TrueForRebalanceOnly() public {
        _enableRebalance();
        runner.setInterval(10 days);
        runner.setLastRun(block.timestamp);

        (int24 outLower, int24 outUpper) = _outOfRangeTicksAboveCurrent();
        _setStrategyRange(outLower, outUpper, 5_000);

        (bool upkeepNeeded, bytes memory performData) = runner.checkUpkeep("");
        (uint256 idleFromData, bool investNeeded, bool rebalanceCheckNeeded) =
            abi.decode(performData, (uint256, bool, bool));

        assertTrue(upkeepNeeded);
        assertEq(idleFromData, 0);
        assertFalse(investNeeded);
        assertTrue(rebalanceCheckNeeded);
    }

    function testRunnerFork_performUpkeep_AttemptsInvestmentAndUpdatesLastRun() public {
        _grantKeeperRoleToRunner();
        if (runner.skipIfPaused()) runner.toggleSkipIfPaused();
        _registerAndDeposit(makeAddr("member2"), 2_000e6);

        vm.warp(block.timestamp + runner.interval() + 1);
        uint256 idleBefore = vault.idleAssets();
        assertGt(idleBefore, 0, "idle before is zero");

        vm.recordLogs();
        runner.performUpkeep("");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool foundAttempt;
        bool foundVaultInvestEvent;
        bool foundRunnerSuccess;
        bool foundRunnerFailed;
        uint256 requestedAssetsFromVault;
        uint256 investedAssetsFromVault;
        uint256 idleFromAttempt;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(runner) && logs[i].topics.length > 0) {
                if (logs[i].topics[0] == ON_UPKEEP_ATTEMPT_SIG) {
                    foundAttempt = true;
                    (, idleFromAttempt,,) = abi.decode(logs[i].data, (uint256, uint256, uint16, bytes32));
                } else if (logs[i].topics[0] == ON_INVEST_SUCCEEDED_SIG) {
                    foundRunnerSuccess = true;
                } else if (logs[i].topics[0] == ON_INVEST_FAILED_SIG) {
                    foundRunnerFailed = true;
                }
            }

            if (logs[i].emitter == address(vault) && logs[i].topics.length > 0 && logs[i].topics[0] == ON_INVEST_SIG) {
                foundVaultInvestEvent = true;
                (requestedAssetsFromVault, investedAssetsFromVault,) =
                    abi.decode(logs[i].data, (uint256, uint256, bytes32));
            }
        }

        assertTrue(foundAttempt, "runner attempt event not emitted");
        assertEq(idleFromAttempt, idleBefore, "attempt idle mismatch");
        assertTrue(foundRunnerSuccess, "runner success event not emitted");
        assertFalse(foundRunnerFailed, "runner failed event should not exist on happy path");
        assertEq(runner.lastRun(), block.timestamp, "lastRun not updated");
        assertTrue(foundVaultInvestEvent, "vault invest event missing on runner success");
        assertEq(requestedAssetsFromVault, idleBefore, "requested assets mismatch");
        assertGt(investedAssetsFromVault, 0, "vault invested assets is zero");
        assertLe(vault.idleAssets(), idleBefore, "idle did not decrease");
    }

    function testRunnerFork_performUpkeep_EmitsFailedWhenRunnerIsNotKeeper() public {
        // Deliberately do NOT grant KEEPER role to runner.
        if (runner.skipIfPaused()) runner.toggleSkipIfPaused();
        _registerAndDeposit(makeAddr("member3"), 1_500e6);

        vm.warp(block.timestamp + runner.interval() + 1);
        uint256 idleBefore = vault.idleAssets();
        assertGt(idleBefore, 0, "idle before is zero");

        vm.recordLogs();
        runner.performUpkeep("");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool foundAttempt;
        bool foundRunnerSuccess;
        bool foundRunnerFailed;
        bool foundVaultInvestEvent;
        uint256 idleFromAttempt;
        bytes memory failureReason;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(runner) && logs[i].topics.length > 0) {
                if (logs[i].topics[0] == ON_UPKEEP_ATTEMPT_SIG) {
                    foundAttempt = true;
                    (, idleFromAttempt,,) = abi.decode(logs[i].data, (uint256, uint256, uint16, bytes32));
                } else if (logs[i].topics[0] == ON_INVEST_SUCCEEDED_SIG) {
                    foundRunnerSuccess = true;
                } else if (logs[i].topics[0] == ON_INVEST_FAILED_SIG) {
                    foundRunnerFailed = true;
                    (, failureReason) = abi.decode(logs[i].data, (uint256, bytes));
                }
            }

            if (logs[i].emitter == address(vault) && logs[i].topics.length > 0 && logs[i].topics[0] == ON_INVEST_SIG) {
                foundVaultInvestEvent = true;
            }
        }

        assertTrue(foundAttempt, "runner attempt event not emitted");
        assertEq(idleFromAttempt, idleBefore, "attempt idle mismatch");
        assertTrue(foundRunnerFailed, "runner failed event not emitted");
        assertFalse(foundRunnerSuccess, "runner success event should not exist");
        assertFalse(foundVaultInvestEvent, "vault invest event should not exist");
        assertEq(runner.lastRun(), block.timestamp, "lastRun not updated");
        assertEq(
            _errorSelector(failureReason), SFVault.SFVault__NotAuthorizedCaller.selector, "unexpected failure reason"
        );
    }

    function testRunnerFork_performUpkeep_SkipsWhenDependencyPausedAndUpdatesTimestamps() public {
        _enableRebalance();
        _grantKeeperRoleToRunner();
        _registerAndDeposit(makeAddr("memberPaused"), 1_000e6);

        (int24 outLower, int24 outUpper) = _outOfRangeTicksAboveCurrent();
        _setStrategyRange(outLower, outUpper, 5_000);

        vm.prank(pauseGuardian);
        uniV3.pause();

        vm.warp(block.timestamp + runner.interval() + 1);

        vm.recordLogs();
        runner.performUpkeep("");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool foundSkippedPaused;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(runner) && logs[i].topics.length > 0) {
                if (logs[i].topics[0] == ON_UPKEEP_SKIPPED_PAUSED_SIG) {
                    foundSkippedPaused = true;
                }
            }
        }

        assertTrue(foundSkippedPaused, "runner paused-skip event missing");
        assertEq(runner.lastRun(), block.timestamp, "lastRun not updated on paused dependency");
        assertEq(runner.lastRebalanceCheck(), block.timestamp, "lastRebalanceCheck not updated on paused dependency");
        assertEq(uniV3.tickLower(), outLower, "range should remain unchanged");
        assertEq(uniV3.tickUpper(), outUpper, "range should remain unchanged");
    }

    function testRunnerFork_performUpkeep_SkipsLowIdleAndKeepsLastRun() public {
        _grantKeeperRoleToRunner();
        if (runner.skipIfPaused()) runner.toggleSkipIfPaused();
        _registerAndDeposit(makeAddr("memberLowIdle"), 1_000e6);

        uint256 idleBefore = vault.idleAssets();
        runner.setMinIdleAssets(idleBefore + 1);
        vm.warp(block.timestamp + runner.interval() + 1);

        vm.recordLogs();
        runner.performUpkeep("");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool foundLowIdle;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(runner) && logs[i].topics.length > 0) {
                if (logs[i].topics[0] == ON_UPKEEP_SKIPPED_LOW_IDLE_SIG) {
                    foundLowIdle = true;
                }
            }
        }

        assertTrue(foundLowIdle, "runner low-idle event missing");
        assertEq(runner.lastRun(), 0, "lastRun should not advance on low idle");
        assertEq(vault.idleAssets(), idleBefore, "idle should remain untouched");
    }

    function testRunnerFork_previewInvestBundle_AutoRatioMatchesSpotSlot0() public view {
        uint256 assetsIncoming = 1_000e6;

        (uint16 otherRatioBps,, bytes[] memory payloads,) = runner.previewInvestBundle(assetsIncoming);

        IUniswapV3Pool poolAddress = uniV3.pool();
        (uint160 sqrtPriceX96,,,,,,) = poolAddress.slot0();

        uint16 expectedRatioBps = _computeOtherRatioBPS(sqrtPriceX96, uniV3.tickLower(), uniV3.tickUpper());
        if (expectedRatioBps == 0) {
            uint256 underlyingBal = IERC20(address(vault.asset())).balanceOf(address(uniV3)) + assetsIncoming;
            uint256 otherBal = IERC20(address(uniV3.otherToken())).balanceOf(address(uniV3));
            uint256 otherValueInUnderlying = _quoteOtherAsUnderlyingAtSqrtPrice(otherBal, sqrtPriceX96);
            uint256 totalValueInUnderlying = underlyingBal + otherValueInUnderlying;
            if (totalValueInUnderlying > 0) {
                uint256 currentOtherRatioBps = Math.mulDiv(otherValueInUnderlying, MAX_BPS, totalValueInUnderlying);
                if (currentOtherRatioBps >= 1) expectedRatioBps = 1;
            }
        }

        assertEq(otherRatioBps, expectedRatioBps, "auto ratio should be spot-based");

        (uint16 encodedOtherRatioBps,,,,,) = abi.decode(payloads[0], (uint16, bytes, bytes, uint256, uint256, uint256));
        assertEq(encodedOtherRatioBps, otherRatioBps, "payload ratio mismatch");
    }

    function testRunnerFork_previewInvestBundle_ManualRatioZeroSwapAndDeadline() public {
        runner.setUseAutoOtherRatio();
        runner.setManualOtherRatioBPS(4_321);
        runner.setSwapBPS(0, 0);
        runner.setPositionMins(11, 22);
        runner.setDeadlineBuffer(600);

        (uint16 otherRatioBps,, bytes[] memory payloads,) = runner.previewInvestBundle(1_000e6);
        (
            uint16 encodedOtherRatioBps,
            bytes memory swapToOtherData,
            bytes memory swapToUnderlyingData,
            uint256 pmDeadline,
            uint256 minUnderlying,
            uint256 minOther
        ) = abi.decode(payloads[0], (uint16, bytes, bytes, uint256, uint256, uint256));

        assertEq(otherRatioBps, 4_321);
        assertEq(encodedOtherRatioBps, 4_321);
        assertEq(swapToOtherData.length, 0);
        assertEq(swapToUnderlyingData.length, 0);
        assertEq(pmDeadline, block.timestamp + 600);
        assertEq(minUnderlying, 11);
        assertEq(minOther, 22);
    }

    function testRunnerFork_setLastSuccessfulRebalance() public {
        uint256 seededTs = block.timestamp - 8 days;
        runner.setLastSuccessfulRebalance(seededTs);
        assertEq(runner.lastSuccessfulRebalance(), seededTs);
    }

    function testRunnerFork_harness_ObserveAndMaybeRebalance_BlocksCandidateOnPegGuard() public {
        SaveFundsInvestAutomationRunnerHarness harness = new SaveFundsInvestAutomationRunnerHarness();
        MockPoolForRunnerHarness poolMock = new MockPoolForRunnerHarness();
        MockStrategyAutomationView strategyMock = new MockStrategyAutomationView();

        poolMock.setTokens(address(asset), address(uniV3.otherToken()));
        poolMock.setFee(100);
        poolMock.setTickSpacing(1);
        poolMock.setSlot0(TickMathV3.getSqrtRatioAtTick(25), 25);
        poolMock.setObserve(0, 0, false);
        strategyMock.setTicks(0, 10);
        strategyMock.setTwapWindow(30);
        harness.setHarnessConfig(
            address(poolMock), address(strategyMock), address(asset), address(uniV3.otherToken()), false
        );

        uint256 start = block.timestamp + 1;
        vm.warp(start);
        harness.exposedRecordRebalanceSample(2, 100);
        vm.warp(start + 24 hours);

        assertTrue(harness.exposedObserveAndMaybeRebalance(), "peg guard should block the rebalance candidate");
    }

    function testRunnerFork_runnerInventoryRatio_MatchesManualLiveValuation() public {
        SaveFundsInvestAutomationRunnerHarness harness = new SaveFundsInvestAutomationRunnerHarness();
        harness.setHarnessConfig(
            address(uniV3.pool()),
            address(uniV3),
            address(asset),
            address(uniV3.otherToken()),
            uniV3.pool().token0() == address(uniV3.otherToken())
        );

        (uint160 sqrtPriceX96,,,,,,) = uniV3.pool().slot0();
        uint16 ratioBPS = harness.exposedCurrentInventoryOtherRatioBPS();
        uint16 expectedRatioBPS = _manualInventoryOtherRatioBPS(uniV3, sqrtPriceX96);
        assertEq(ratioBPS, expectedRatioBPS, "live ratio should match manual inventory valuation");
    }

    function testRunnerFork_runnerInventoryRatio_ZeroWhenEmptyAndFullWhenOnlyOtherIdle() public {
        SaveFundsInvestAutomationRunnerHarness harness = new SaveFundsInvestAutomationRunnerHarness();
        MockPoolForRunnerHarness poolMock = new MockPoolForRunnerHarness();
        MockStrategyAutomationView strategyMock = new MockStrategyAutomationView();

        poolMock.setTokens(address(asset), address(uniV3.otherToken()));
        poolMock.setSlot0(1 << 96, 0);
        strategyMock.setTwapWindow(30);
        harness.setHarnessConfig(
            address(poolMock),
            address(strategyMock),
            address(asset),
            address(uniV3.otherToken()),
            false
        );

        assertEq(harness.exposedCurrentInventoryOtherRatioBPS(), 0, "empty strategy should report zero ratio");

        deal(address(uniV3.otherToken()), address(strategyMock), 100e6);
        assertEq(
            harness.exposedCurrentInventoryOtherRatioBPS(), 10_000, "pure other-token inventory should report 100%"
        );
    }

    function testRunnerFork_harness_SpacingMathAndRatioBoundaries() public {
        SaveFundsInvestAutomationRunnerHarness harness = new SaveFundsInvestAutomationRunnerHarness();
        MockPoolForRunnerHarness poolMock = new MockPoolForRunnerHarness();

        harness.setHarnessConfig(address(poolMock), address(0), address(1), address(2), true);
        assertEq(harness.exposedFloorToSpacing(-3, 2), -4);
        assertEq(harness.exposedCeilToSpacing(3, 2), 4);

        int24 tickLower = -10;
        int24 tickUpper = 10;
        uint160 lowerSqrtPrice = TickMathV3.getSqrtRatioAtTick(tickLower);
        uint160 upperSqrtPrice = TickMathV3.getSqrtRatioAtTick(tickUpper);
        uint160 midSqrtPrice = TickMathV3.getSqrtRatioAtTick(0);

        assertEq(harness.exposedComputeOtherRatioBPS(lowerSqrtPrice, tickLower, tickUpper), 10_000);
        assertEq(harness.exposedComputeOtherRatioBPS(upperSqrtPrice, tickLower, tickUpper), 0);

        uint16 inRangeRatio = harness.exposedComputeOtherRatioBPS(midSqrtPrice, tickLower, tickUpper);
        assertGt(inRangeRatio, 0);
        assertLt(inRangeRatio, 10_000);

        harness.setHarnessConfig(address(poolMock), address(0), address(1), address(2), false);
        assertEq(harness.exposedComputeOtherRatioBPS(lowerSqrtPrice, tickLower, tickUpper), 0);
        assertEq(harness.exposedComputeOtherRatioBPS(upperSqrtPrice, tickLower, tickUpper), 10_000);
    }

    function testRunnerFork_harness_QuoteAndPausedHelpers() public {
        SaveFundsInvestAutomationRunnerHarness harness = new SaveFundsInvestAutomationRunnerHarness();
        MockPoolForRunnerHarness poolMock = new MockPoolForRunnerHarness();
        MockPausedTarget pausedTarget = new MockPausedTarget();
        MockMalformedPausedTarget malformedTarget = new MockMalformedPausedTarget();
        uint160 sqrtPriceX96 = 1 << 96;

        poolMock.setTokens(address(11), address(12));
        harness.setHarnessConfig(address(poolMock), address(0), address(12), address(11), true);
        assertEq(harness.exposedQuoteOtherAsUnderlyingAtSqrtPrice(5, sqrtPriceX96), 5);
        assertEq(harness.exposedQuoteOtherAsUnderlyingAtSqrtPrice(0, sqrtPriceX96), 0);

        poolMock.setTokens(address(21), address(22));
        harness.setHarnessConfig(address(poolMock), address(0), address(21), address(22), false);
        assertEq(harness.exposedQuoteOtherAsUnderlyingAtSqrtPrice(7, sqrtPriceX96), 7);

        harness.setHarnessConfig(address(poolMock), address(0), address(31), address(31), false);
        assertEq(harness.exposedQuoteOtherAsUnderlyingAtSqrtPrice(9, sqrtPriceX96), 9);

        // The helper now relies on initialization-time pool validation and only uses `otherIsToken0`
        // to choose the conversion direction at runtime.
        poolMock.setTokens(address(41), address(42));
        harness.setHarnessConfig(address(poolMock), address(0), address(43), address(44), false);
        assertEq(harness.exposedQuoteOtherAsUnderlyingAtSqrtPrice(1, sqrtPriceX96), 1);

        pausedTarget.setPaused(true);
        assertTrue(harness.exposedIsPaused(address(pausedTarget)));
        pausedTarget.setPaused(false);
        assertFalse(harness.exposedIsPaused(address(pausedTarget)));
        assertFalse(harness.exposedIsPaused(address(malformedTarget)));
        assertFalse(harness.exposedIsPaused(address(0x1234)));
    }

    function testRunnerFork_harness_RebalanceSampleAndTriggerLogic() public {
        SaveFundsInvestAutomationRunnerHarness harness = new SaveFundsInvestAutomationRunnerHarness();
        MockPoolForRunnerHarness poolMock = new MockPoolForRunnerHarness();
        MockStrategyAutomationView strategyMock = new MockStrategyAutomationView();

        poolMock.setTokens(address(61), address(62));
        poolMock.setFee(100);
        poolMock.setTickSpacing(1);
        poolMock.setSlot0(1 << 96, 7);
        strategyMock.setTicks(0, 10);
        strategyMock.setTwapWindow(30);
        deal(address(asset), address(strategyMock), 55e6);
        deal(address(uniV3.otherToken()), address(strategyMock), 45e6);
        poolMock.setTokens(address(asset), address(uniV3.otherToken()));
        harness.setHarnessConfig(
            address(poolMock), address(strategyMock), address(asset), address(uniV3.otherToken()), false
        );
        harness.exposedInitializeRebalanceState();

        assertEq(harness.exposedRebalanceSampleCount(), 1);
        assertEq(harness.exposedRebalanceSampleHead(), 1);
        assertEq(harness.exposedRebalanceSampleTimestamp(0), block.timestamp - 24 hours);
        assertFalse(harness.exposedRebalanceSampleOutOfRange(0));
        assertEq(harness.exposedRebalanceSampleRangeSide(0), 0);
        assertEq(harness.exposedRebalanceSampleInventoryOtherRatioBPS(0), 4_500);
        assertEq(harness.exposedConsecutiveInventoryOneSidedObserved(2_000), 0);
        assertEq(harness.exposedRollingSameSideObserved(1, block.timestamp - 1 days), 0);
        assertFalse(harness.exposedHasRecentOutOfRangeSample(block.timestamp - 2 days));

        vm.warp(100);
        harness.exposedRecordRebalanceSample(1, 1_500);
        assertEq(harness.exposedConsecutiveInventoryOneSidedObserved(2_000), 0);

        vm.warp(200);
        harness.exposedRecordRebalanceSample(1, 1_500);
        vm.warp(300);
        harness.exposedRecordRebalanceSample(1, 1_500);

        assertEq(harness.exposedConsecutiveInventoryOneSidedObserved(2_000), 200);
        assertEq(harness.exposedRollingSameSideObserved(1, 250), 50);
        assertTrue(harness.exposedHasRecentOutOfRangeSample(250));

        assertEq(harness.exposedRebalanceTriggerPath(0, 24 hours, 24 hours, 24 hours), 0);
        assertEq(harness.exposedRebalanceTriggerPath(1, 24 hours, 0, 0), 1);
        assertEq(harness.exposedRebalanceTriggerPath(1, 0, 17 hours, 24 hours), 0);
        assertEq(harness.exposedRebalanceTriggerPath(1, 0, 18 hours, 24 hours), 2);

        for (uint256 i; i < 17; ++i) {
            vm.warp(block.timestamp + 1);
            harness.exposedRecordRebalanceSample(1, 1_500);
        }

        assertEq(harness.exposedRebalanceSampleCount(), 16);
        assertEq(harness.exposedSampleIndexFromNewest(0), (uint256(harness.exposedRebalanceSampleHead()) + 15) % 16);

        harness.exposedClearRebalanceSamples();
        assertEq(harness.exposedRebalanceSampleCount(), 0);
        assertEq(harness.exposedRebalanceSampleHead(), 0);
    }

    function testRunnerFork_harness_ValuationMonitoringPegGuardAndRebalanceChecks() public {
        SaveFundsInvestAutomationRunnerHarness harness = new SaveFundsInvestAutomationRunnerHarness();
        MockPoolForRunnerHarness poolMock = new MockPoolForRunnerHarness();
        MockStrategyAutomationView strategyMock = new MockStrategyAutomationView();

        poolMock.setTokens(address(51), address(52));
        poolMock.setFee(100);
        poolMock.setTickSpacing(1);
        strategyMock.setTwapWindow(30);
        deal(address(asset), address(strategyMock), 35e6);
        deal(address(uniV3.otherToken()), address(strategyMock), 65e6);
        poolMock.setTokens(address(asset), address(uniV3.otherToken()));
        harness.setHarnessConfig(
            address(poolMock), address(strategyMock), address(asset), address(uniV3.otherToken()), false
        );

        poolMock.setSlot0(1 << 96, 7);
        strategyMock.setTicks(0, 10);
        assertEq(harness.exposedValuationSqrtPriceX96(0), uint160(1 << 96));
        assertEq(harness.exposedCurrentMonitoringTick(), 7);
        assertEq(harness.exposedCurrentInventoryOtherRatioBPS(), 6_500);
        (uint8 rangeSideSpot, int24 currentTickSpot,,) = harness.exposedCurrentRangeStatus();
        assertEq(rangeSideSpot, 0);
        assertEq(currentTickSpot, 7);

        poolMock.setSlot0(0, 7);
        poolMock.setObserve(0, 300, false);
        assertEq(harness.exposedValuationSqrtPriceX96(30), TickMathV3.getSqrtRatioAtTick(10));
        assertEq(harness.exposedCurrentMonitoringTick(), 10);

        poolMock.setObserve(0, -31, false);
        assertEq(harness.exposedValuationSqrtPriceX96(30), TickMathV3.getSqrtRatioAtTick(-2));

        poolMock.setSlot0(1 << 96, 11);
        poolMock.setObserve(0, 0, true);
        assertEq(harness.exposedValuationSqrtPriceX96(30), uint160(1 << 96));

        poolMock.setSlot0(0, 13);
        assertEq(harness.exposedCurrentMonitoringTick(), 13);

        harness.setHarnessTiming(0, 0, 12 hours, block.timestamp, 0, false);
        assertFalse(harness.exposedShouldCheckRebalance());

        harness.setHarnessTiming(0, 0, 12 hours, block.timestamp, 0, true);
        assertFalse(harness.exposedShouldCheckRebalance());

        harness.setHarnessTiming(0, 0, 12 hours, block.timestamp - 13 hours, 0, true);
        strategyMock.setTicks(20, 30);
        assertTrue(harness.exposedShouldCheckRebalance());

        strategyMock.setTicks(0, 20);
        assertFalse(harness.exposedShouldCheckRebalance());

        vm.warp(block.timestamp + 1);
        harness.exposedRecordRebalanceSample(1, 1_500);
        assertTrue(harness.exposedShouldCheckRebalance());

        poolMock.setSlot0(1 << 96, 0);
        poolMock.setObserve(0, 0, false);
        (bool guardPassed, uint16 pegDeviation, uint16 twapDeviation) = harness.exposedEvaluatePegGuard();
        assertTrue(guardPassed);
        assertEq(pegDeviation, 0);
        assertEq(twapDeviation, 0);

        poolMock.setSlot0(TickMathV3.getSqrtRatioAtTick(25), 25);
        poolMock.setObserve(0, 0, false);
        (guardPassed, pegDeviation, twapDeviation) = harness.exposedEvaluatePegGuard();
        assertFalse(guardPassed);
        assertGt(pegDeviation, 10);
        assertGt(twapDeviation, 10);
    }

    function _getAddr(string memory contractName) internal view returns (address) {
        return addrGetter.getAddress(block.chainid, contractName);
    }

    function _ensureBackendAdmin() internal {
        if (backendAdmin != address(0) && addrMgr.hasRole(Roles.BACKEND_ADMIN, backendAdmin)) return;

        address owner = addrMgr.owner();
        backendAdmin = makeAddr("backendAdminRunner");

        vm.prank(owner);
        addrMgr.proposeRoleHolder(Roles.BACKEND_ADMIN, backendAdmin);

        vm.prank(backendAdmin);
        addrMgr.acceptProposedRole(Roles.BACKEND_ADMIN);
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

    function _grantKeeperRoleToRunner() internal {
        address owner = addrMgr.owner();
        vm.prank(owner);
        addrMgr.proposeRoleHolder(Roles.KEEPER, address(runner));
        runner.acceptKeeperRole();
    }

    function _enableRebalance() internal {
        if (!runner.rebalanceEnabled()) runner.toggleRebalanceEnabled();
    }

    function _registerAndDeposit(address user, uint256 amount) internal {
        vm.prank(backendAdmin);
        vault.registerMember(user);

        uint256 maxDep = vault.maxDeposit(user);
        uint256 toDeposit = amount > maxDep ? maxDep : amount;
        require(toDeposit > 0, "maxDeposit is zero");

        deal(address(asset), user, toDeposit);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(toDeposit, user);
        vm.stopPrank();
    }

    function _computeOtherRatioBPS(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint16)
    {
        uint160 sa = TickMathV3.getSqrtRatioAtTick(tickLower);
        uint160 sb = TickMathV3.getSqrtRatioAtTick(tickUpper);
        if (sa > sb) (sa, sb) = (sb, sa);

        bool otherIsToken0 = runner.otherIsToken0();
        if (sqrtPriceX96 <= sa) return otherIsToken0 ? uint16(MAX_BPS) : uint16(0);
        if (sqrtPriceX96 >= sb) return otherIsToken0 ? uint16(0) : uint16(MAX_BPS);

        uint256 token0ValueInToken1 = Math.mulDiv(uint256(sb - sqrtPriceX96), uint256(sqrtPriceX96), uint256(sb));
        uint256 token1ValueInToken1 = uint256(sqrtPriceX96 - sa);
        uint256 totalValueInToken1 = token0ValueInToken1 + token1ValueInToken1;
        if (totalValueInToken1 == 0) return 0;

        uint256 otherValueInToken1 = otherIsToken0 ? token0ValueInToken1 : token1ValueInToken1;
        return uint16(Math.mulDiv(otherValueInToken1, MAX_BPS, totalValueInToken1));
    }

    function _quoteOtherAsUnderlyingAtSqrtPrice(uint256 amountOther, uint160 sqrtPriceX96)
        internal
        view
        returns (uint256)
    {
        if (amountOther == 0) return 0;

        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 q192 = 1 << 192;

        address token0 = uniV3.pool().token0();
        address token1 = uniV3.pool().token1();
        address underlying = address(vault.asset());
        address other = address(uniV3.otherToken());

        if (other == token0 && underlying == token1) return Math.mulDiv(amountOther, priceX192, q192);
        if (other == token1 && underlying == token0) return Math.mulDiv(amountOther, q192, priceX192);
        revert("bad pool config");
    }

    function _manualInventoryOtherRatioBPS(SFUniswapV3Strategy strategy, uint160 sqrtPriceX96)
        internal
        view
        returns (uint16)
    {
        (uint256 underlyingValue, uint256 otherValueInUnderlying) =
            _manualPositionInventoryValues(strategy.positionTokenId(), sqrtPriceX96);
        address strategyAddr = address(strategy);

        (underlyingValue, otherValueInUnderlying) = _accumulateInventoryLeg(
            underlyingValue,
            otherValueInUnderlying,
            address(asset),
            IERC20(address(asset)).balanceOf(strategyAddr),
            sqrtPriceX96
        );
        (underlyingValue, otherValueInUnderlying) = _accumulateInventoryLeg(
            underlyingValue,
            otherValueInUnderlying,
            address(uniV3.otherToken()),
            IERC20(address(uniV3.otherToken())).balanceOf(strategyAddr),
            sqrtPriceX96
        );

        uint256 totalValue = underlyingValue + otherValueInUnderlying;
        if (totalValue == 0) return 0;
        return uint16(Math.mulDiv(otherValueInUnderlying, MAX_BPS, totalValue));
    }

    function _manualPositionInventoryValues(uint256 tokenId, uint160 sqrtPriceX96)
        internal
        view
        returns (uint256 underlyingValue, uint256 otherValueInUnderlying)
    {
        if (tokenId == 0) return (0, 0);

        INonfungiblePositionManager positionManager = INonfungiblePositionManager(UNI_V3_POSITION_MANAGER_ARBITRUM);
        address t0 = PositionReader._getAddress(positionManager, tokenId, 2);
        address t1 = PositionReader._getAddress(positionManager, tokenId, 3);
        (underlyingValue, otherValueInUnderlying) =
            _manualLiquidityInventoryValues(positionManager, tokenId, t0, t1, sqrtPriceX96);

        uint128 owed0 = PositionReader._getUint128(positionManager, tokenId, 10);
        uint128 owed1 = PositionReader._getUint128(positionManager, tokenId, 11);

        (underlyingValue, otherValueInUnderlying) =
            _accumulateInventoryLeg(underlyingValue, otherValueInUnderlying, t0, uint256(owed0), sqrtPriceX96);
        (underlyingValue, otherValueInUnderlying) =
            _accumulateInventoryLeg(underlyingValue, otherValueInUnderlying, t1, uint256(owed1), sqrtPriceX96);
    }

    function _manualLiquidityInventoryValues(
        INonfungiblePositionManager positionManager,
        uint256 tokenId,
        address t0,
        address t1,
        uint160 sqrtPriceX96
    ) internal view returns (uint256 underlyingValue, uint256 otherValueInUnderlying) {
        int24 tl = PositionReader._getInt24(positionManager, tokenId, 5);
        int24 tu = PositionReader._getInt24(positionManager, tokenId, 6);
        uint128 liq = PositionReader._getUint128(positionManager, tokenId, 7);
        if (liq == 0) return (0, 0);

        (uint256 a0, uint256 a1) = LiquidityAmountsV3.getAmountsForLiquidity(
            sqrtPriceX96, TickMathV3.getSqrtRatioAtTick(tl), TickMathV3.getSqrtRatioAtTick(tu), liq
        );
        (underlyingValue, otherValueInUnderlying) =
            _accumulateInventoryLeg(underlyingValue, otherValueInUnderlying, t0, a0, sqrtPriceX96);
        (underlyingValue, otherValueInUnderlying) =
            _accumulateInventoryLeg(underlyingValue, otherValueInUnderlying, t1, a1, sqrtPriceX96);
    }

    function _accumulateInventoryLeg(
        uint256 underlyingValue,
        uint256 otherValueInUnderlying,
        address token,
        uint256 amount,
        uint160 sqrtPriceX96
    ) internal view returns (uint256 newUnderlyingValue, uint256 newOtherValueInUnderlying) {
        newUnderlyingValue = underlyingValue;
        newOtherValueInUnderlying = otherValueInUnderlying;
        if (amount == 0) return (newUnderlyingValue, newOtherValueInUnderlying);

        if (token == address(asset)) {
            newUnderlyingValue += amount;
        } else if (token == address(uniV3.otherToken())) {
            newOtherValueInUnderlying += _quoteOtherAsUnderlyingAtSqrtPrice(amount, sqrtPriceX96);
        }
    }

    function _errorSelector(bytes memory revertData) internal pure returns (bytes4 selector) {
        require(revertData.length >= 4, "revert data too short");
        assembly {
            selector := mload(add(revertData, 32))
        }
    }

    function _setStrategyRange(int24 newTickLower, int24 newTickUpper, uint16 otherRatioBps) internal {
        bytes memory bundle = _buildRebalanceBundle(newTickLower, newTickUpper, otherRatioBps);
        vm.prank(operator);
        aggregator.rebalance(bundle);
    }

    function _buildRebalanceBundle(int24 newTickLower, int24 newTickUpper, uint16 otherRatioBps)
        internal
        view
        returns (bytes memory)
    {
        bytes memory actionData = abi.encode(
            otherRatioBps,
            _buildSwapData(address(asset), address(uniV3.otherToken()), 10_000),
            _buildSwapData(address(uniV3.otherToken()), address(asset), 10_000),
            uint256(0),
            uint256(0),
            uint256(0)
        );
        bytes memory payload = abi.encode(newTickLower, newTickUpper, actionData);

        address[] memory strategies = new address[](1);
        strategies[0] = address(uniV3);

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;

        return abi.encode(strategies, payloads);
    }

    function _buildSwapData(address tokenIn, address tokenOut, uint16 bps) internal view returns (bytes memory) {
        bytes memory path = abi.encodePacked(tokenIn, uniV3.pool().fee(), tokenOut);
        uint256 amountIn = AMOUNT_IN_BPS_FLAG | uint256(bps);
        bytes memory input = abi.encode(address(uniV3), amountIn, uint256(0), path, true);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = input;

        return abi.encode(inputs, uint256(0));
    }

    function _currentPoolTick() internal view returns (int24 currentTick) {
        (, currentTick,,,,,) = uniV3.pool().slot0();
    }

    function _expectedRunnerTicks(int24 currentTick) internal view returns (int24 lower, int24 upper) {
        int24 spacing = uniV3.pool().tickSpacing();
        lower = _floorToSpacing(currentTick - 2, spacing);
        upper = _ceilToSpacing(currentTick + 3, spacing);
    }

    function _outOfRangeTicksAboveCurrent() internal view returns (int24 lower, int24 upper) {
        int24 spacing = uniV3.pool().tickSpacing();
        int24 currentTick = _currentPoolTick();
        lower = _ceilToSpacing(currentTick + 25, spacing);
        upper = lower + spacing * 5;
    }

    function _outOfRangeTicksBelowCurrent() internal view returns (int24 lower, int24 upper) {
        int24 spacing = uniV3.pool().tickSpacing();
        int24 currentTick = _currentPoolTick();
        upper = _floorToSpacing(currentTick - 25, spacing);
        lower = upper - spacing * 5;
    }

    function _inRangeTicksAroundCurrent() internal view returns (int24 lower, int24 upper) {
        int24 spacing = uniV3.pool().tickSpacing();
        int24 currentTick = _currentPoolTick();
        lower = _floorToSpacing(currentTick - 2, spacing);
        upper = _ceilToSpacing(currentTick + 3, spacing);
    }

    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 q = tick / spacing;
        int24 r = tick % spacing;
        if (tick < 0 && r != 0) q -= 1;
        return q * spacing;
    }

    function _ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 q = tick / spacing;
        int24 r = tick % spacing;
        if (tick > 0 && r != 0) q += 1;
        return q * spacing;
    }
}

contract AddressGetter is GetContractAddress {
    function getAddress(uint256 chainId, string memory contractName) external view returns (address) {
        return _getContractAddress(chainId, contractName);
    }
}

contract SaveFundsInvestAutomationRunnerHarness is SaveFundsInvestAutomationRunner {
    function setHarnessConfig(address _pool, address _uniStrategy, address _underlyingToken, address _otherToken, bool _otherIsToken0)
        external
    {
        pool = IUniswapV3Pool(_pool);
        uniStrategy = _uniStrategy;
        underlyingToken = _underlyingToken;
        otherToken = _otherToken;
        otherIsToken0 = _otherIsToken0;
    }

    function setHarnessTiming(
        uint256 _interval,
        uint256 _lastRun,
        uint256 _rebalanceCheckInterval,
        uint256 _lastRebalanceCheck,
        uint256 _lastSuccessfulRebalance,
        bool _rebalanceEnabled
    ) external {
        interval = _interval;
        lastRun = _lastRun;
        rebalanceCheckInterval = _rebalanceCheckInterval;
        lastRebalanceCheck = _lastRebalanceCheck;
        lastSuccessfulRebalance = _lastSuccessfulRebalance;
        rebalanceEnabled = _rebalanceEnabled;
    }

    function exposedInitializeRebalanceState() external {
        _initializeRebalanceState();
    }

    function exposedFloorToSpacing(int24 tick, int24 spacing) external pure returns (int24) {
        return _floorToSpacing(tick, spacing);
    }

    function exposedCeilToSpacing(int24 tick, int24 spacing) external pure returns (int24) {
        return _ceilToSpacing(tick, spacing);
    }

    function exposedComputeOtherRatioBPS(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint16)
    {
        return _computeOtherRatioBPS(sqrtPriceX96, tickLower, tickUpper);
    }

    function exposedQuoteOtherAsUnderlyingAtSqrtPrice(uint256 amountOther, uint160 sqrtPriceX96)
        external
        view
        returns (uint256)
    {
        return _quoteOtherAsUnderlyingAtSqrtPrice(amountOther, sqrtPriceX96);
    }

    function exposedIsPaused(address target) external view returns (bool) {
        return _isPaused(target);
    }

    function exposedRecordRebalanceSample(uint8 rangeSide, uint16 inventoryOtherRatioBPS) external {
        _recordRebalanceSample(rangeSide, inventoryOtherRatioBPS);
    }

    function exposedClearRebalanceSamples() external {
        _clearRebalanceSamples();
    }

    function exposedConsecutiveInventoryOneSidedObserved(uint16 oneSidedThresholdBPS) external view returns (uint256) {
        return _consecutiveInventoryOneSidedObserved(oneSidedThresholdBPS);
    }

    function exposedRollingSameSideObserved(uint8 rangeSide, uint256 windowStart) external view returns (uint256) {
        return _rollingSameSideObserved(rangeSide, windowStart);
    }

    function exposedHasRecentOutOfRangeSample(uint256 windowStart) external view returns (bool) {
        return _hasRecentOutOfRangeSample(windowStart);
    }

    function exposedRebalanceTriggerPath(
        uint8 rangeSide,
        uint256 ordinaryInventoryObserved,
        uint256 sameSideObserved,
        uint256 oscillationInventoryObserved
    )
        external
        pure
        returns (uint8)
    {
        return _rebalanceTriggerPath(rangeSide, ordinaryInventoryObserved, sameSideObserved, oscillationInventoryObserved);
    }

    function exposedSampleIndexFromNewest(uint256 offset) external view returns (uint256) {
        return _sampleIndexFromNewest(offset);
    }

    function exposedRebalanceSampleCount() external view returns (uint8) {
        return rebalanceSampleCount;
    }

    function exposedRebalanceSampleHead() external view returns (uint8) {
        return rebalanceSampleHead;
    }

    function exposedRebalanceSampleTimestamp(uint256 index) external view returns (uint256) {
        return rebalanceSampleTimestamps[index];
    }

    function exposedRebalanceSampleOutOfRange(uint256 index) external view returns (bool) {
        return rebalanceSampleOutOfRange[index];
    }

    function exposedRebalanceSampleRangeSide(uint256 index) external view returns (uint8) {
        return rebalanceSampleRangeSides[index];
    }

    function exposedRebalanceSampleInventoryOtherRatioBPS(uint256 index) external view returns (uint16) {
        return rebalanceSampleInventoryOtherRatioBPS[index];
    }

    function exposedValuationSqrtPriceX96(uint32 window) external view returns (uint160) {
        return _valuationSqrtPriceX96(window);
    }

    function exposedCurrentInventoryOtherRatioBPS() external view returns (uint16) {
        return _currentInventoryOtherRatioBPS();
    }

    function exposedEvaluatePegGuard()
        external
        view
        returns (bool passed, uint16 spotPegDeviationBPS, uint16 spotVsTwapDeviationBPS)
    {
        PegGuardStatus memory status = _evaluatePegGuard();
        return (status.passed, status.spotPegDeviationBPS, status.spotVsTwapDeviationBPS);
    }

    function exposedCurrentMonitoringTick() external view returns (int24) {
        return _currentMonitoringTick();
    }

    function exposedCurrentRangeStatus()
        external
        view
        returns (uint8 rangeSide_, int24 currentTick_, int24 tickLower_, int24 tickUpper_)
    {
        return _currentRangeStatus();
    }

    function exposedShouldCheckRebalance() external view returns (bool) {
        return _shouldCheckRebalance();
    }

    function exposedObserveAndMaybeRebalance() external returns (bool) {
        return _observeAndMaybeRebalance();
    }
}

contract MockPoolForRunnerHarness {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;
    uint160 public sqrtPriceX96;
    int24 public tick;
    bool public revertObserve;
    int56 public tickCumulativeOld;
    int56 public tickCumulativeNew;

    function setTokens(address _token0, address _token1) external {
        token0 = _token0;
        token1 = _token1;
    }

    function setFee(uint24 _fee) external {
        fee = _fee;
    }

    function setTickSpacing(int24 _tickSpacing) external {
        tickSpacing = _tickSpacing;
    }

    function setSlot0(uint160 _sqrtPriceX96, int24 _tick) external {
        sqrtPriceX96 = _sqrtPriceX96;
        tick = _tick;
    }

    function setObserve(int56 _tickCumulativeOld, int56 _tickCumulativeNew, bool _revertObserve) external {
        tickCumulativeOld = _tickCumulativeOld;
        tickCumulativeNew = _tickCumulativeNew;
        revertObserve = _revertObserve;
    }

    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (sqrtPriceX96, tick, 0, 0, 0, 0, true);
    }

    function observe(uint32[] calldata)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        require(!revertObserve, "observe revert");

        tickCumulatives = new int56[](2);
        tickCumulatives[0] = tickCumulativeOld;
        tickCumulatives[1] = tickCumulativeNew;
        secondsPerLiquidityCumulativeX128s = new uint160[](2);
    }
}

contract MockStrategyAutomationView {
    address public pool;
    address public asset;
    address public otherToken;
    uint256 public positionTokenId;
    int24 public tickLower;
    int24 public tickUpper;
    uint32 public twapWindow;

    function setTicks(int24 _tickLower, int24 _tickUpper) external {
        tickLower = _tickLower;
        tickUpper = _tickUpper;
    }

    function setPositionTokenId(uint256 _positionTokenId) external {
        positionTokenId = _positionTokenId;
    }

    function setTwapWindow(uint32 _twapWindow) external {
        twapWindow = _twapWindow;
    }
}

contract MockPausedTarget {
    bool public paused;

    function setPaused(bool _paused) external {
        paused = _paused;
    }
}

contract MockMalformedPausedTarget {
    fallback() external {
        assembly {
            mstore(0, 0x01)
            return(0, 1)
        }
    }
}
