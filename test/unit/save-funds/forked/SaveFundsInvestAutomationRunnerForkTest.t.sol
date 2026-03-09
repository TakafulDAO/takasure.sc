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
import {TickMathV3} from "contracts/helpers/uniswapHelpers/libraries/TickMathV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract SaveFundsInvestAutomationRunnerForkTest is Test {
    uint256 internal constant FORK_BLOCK = 430826360;
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant AMOUNT_IN_BPS_FLAG = 1 << 255;
    bytes32 internal constant ON_INVEST_SIG = keccak256("OnInvestIntoStrategy(uint256,uint256,bytes32)");
    bytes32 internal constant ON_UPKEEP_ATTEMPT_SIG = keccak256("OnUpkeepAttempt(uint256,uint256,uint16,bytes32)");
    bytes32 internal constant ON_INVEST_SUCCEEDED_SIG = keccak256("OnInvestSucceeded(uint256,uint256,uint256,uint16)");
    bytes32 internal constant ON_INVEST_FAILED_SIG = keccak256("OnInvestFailed(uint256,bytes)");

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

        assertEq(upgradeRunner.rebalanceCheckInterval(), 12 hours);
        assertEq(upgradeRunner.lastRebalanceCheck(), 0);
        assertEq(upgradeRunner.lastSuccessfulRebalance(), 0);
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

    function testRunnerFork_checkUpkeep_TrueAfterDepositAndInterval() public {
        _registerAndDeposit(makeAddr("member1"), 1_000e6);
        vm.warp(block.timestamp + runner.interval() + 1);

        (bool upkeepNeeded, bytes memory performData) = runner.checkUpkeep("");
        (uint256 idleFromData, bool investNeeded,) = abi.decode(performData, (uint256, bool, bool));

        assertTrue(upkeepNeeded);
        assertTrue(investNeeded);
        assertEq(idleFromData, vault.idleAssets());
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
        assertTrue(foundRunnerSuccess || foundRunnerFailed, "runner terminal event missing");
        assertTrue(!(foundRunnerSuccess && foundRunnerFailed), "runner emitted both success and failed");
        assertEq(runner.lastRun(), block.timestamp, "lastRun not updated");

        if (foundRunnerSuccess) {
            assertTrue(foundVaultInvestEvent, "vault invest event missing on runner success");
            assertEq(requestedAssetsFromVault, idleBefore, "requested assets mismatch");
            assertGt(investedAssetsFromVault, 0, "vault invested assets is zero");
            assertLe(vault.idleAssets(), idleBefore, "idle did not decrease");
        } else {
            // On failed path, vault invest should not complete and emit.
            assertFalse(foundVaultInvestEvent, "vault invest event should not exist on runner failure");
        }
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
            }
        }

        assertTrue(foundAttempt, "runner attempt event not emitted");
        assertEq(idleFromAttempt, idleBefore, "attempt idle mismatch");
        assertTrue(foundRunnerFailed, "runner failed event not emitted");
        assertFalse(foundRunnerSuccess, "runner success event should not exist");
        assertFalse(foundVaultInvestEvent, "vault invest event should not exist");
        assertEq(runner.lastRun(), block.timestamp, "lastRun not updated");
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

        (uint16 encodedOtherRatioBps,,,,,) =
            abi.decode(payloads[0], (uint16, bytes, bytes, uint256, uint256, uint256));
        assertEq(encodedOtherRatioBps, otherRatioBps, "payload ratio mismatch");
    }

    function testRunnerFork_setLastSuccessfulRebalance() public {
        uint256 seededTs = block.timestamp - 8 days;
        runner.setLastSuccessfulRebalance(seededTs);
        assertEq(runner.lastSuccessfulRebalance(), seededTs);
    }

    function testRunnerFork_performUpkeep_RebalancesAfter24HoursOutOfRange() public {
        _enableRebalance();
        _grantKeeperRoleToRunner();

        runner.setInterval(10 days);
        runner.setLastRun(block.timestamp);

        (int24 outLower, int24 outUpper) = _outOfRangeTicksAboveCurrent();
        _setStrategyRange(outLower, outUpper, 5_000);

        runner.performUpkeep("");

        vm.warp(block.timestamp + runner.rebalanceCheckInterval() + 1);
        runner.performUpkeep("");

        vm.warp(block.timestamp + runner.rebalanceCheckInterval() + 1);
        int24 preRebalanceTick = _currentPoolTick();
        (int24 expectedLower, int24 expectedUpper) = _expectedRunnerTicks(preRebalanceTick);

        runner.performUpkeep("");

        assertEq(uniV3.tickLower(), expectedLower, "runner lower tick mismatch");
        assertEq(uniV3.tickUpper(), expectedUpper, "runner upper tick mismatch");
        assertEq(runner.lastSuccessfulRebalance(), block.timestamp, "lastSuccessfulRebalance not updated");
    }

    function testRunnerFork_performUpkeep_RebalancesAfter24HoursWithin3DaysWhenCooldownElapsed() public {
        _enableRebalance();
        _grantKeeperRoleToRunner();

        runner.setInterval(10 days);
        runner.setLastRun(block.timestamp);
        runner.setLastSuccessfulRebalance(block.timestamp - 8 days);

        (int24 outLower1, int24 outUpper1) = _outOfRangeTicksAboveCurrent();
        _setStrategyRange(outLower1, outUpper1, 5_000);

        runner.performUpkeep("");

        vm.warp(block.timestamp + runner.rebalanceCheckInterval() + 1);
        runner.performUpkeep("");

        (int24 inLower, int24 inUpper) = _inRangeTicksAroundCurrent();
        _setStrategyRange(inLower, inUpper, 5_000);

        vm.warp(block.timestamp + runner.rebalanceCheckInterval() + 1);
        runner.performUpkeep("");

        (int24 outLower2, int24 outUpper2) = _outOfRangeTicksBelowCurrent();
        _setStrategyRange(outLower2, outUpper2, 5_000);

        vm.warp(block.timestamp + runner.rebalanceCheckInterval() + 1);
        runner.performUpkeep("");

        vm.warp(block.timestamp + runner.rebalanceCheckInterval() + 1);
        int24 preRebalanceTick = _currentPoolTick();
        (int24 expectedLower, int24 expectedUpper) = _expectedRunnerTicks(preRebalanceTick);

        runner.performUpkeep("");

        assertEq(uniV3.tickLower(), expectedLower, "runner lower tick mismatch");
        assertEq(uniV3.tickUpper(), expectedUpper, "runner upper tick mismatch");
        assertEq(runner.lastSuccessfulRebalance(), block.timestamp, "cooldown-based rebalance not recorded");
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

    function _computeOtherRatioBPS(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper) internal view returns (uint16) {
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

    function _quoteOtherAsUnderlyingAtSqrtPrice(uint256 amountOther, uint160 sqrtPriceX96) internal view returns (uint256) {
        if (amountOther == 0) return 0;

        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 q192 = 1 << 192;

        address token0 = uniV3.pool().token0();
        address token1 = uniV3.pool().token1();
        address underlying = address(vault.asset());
        address other = address(uniV3.otherToken());

        if (other == token0 && underlying == token1) return Math.mulDiv(amountOther, priceX192, q192);
        if (other == token1 && underlying == token0) return Math.mulDiv(amountOther, q192, priceX192);
        return 0;
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
