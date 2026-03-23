// SPDX-License-Identifier: GPL-3.0

/**
 * @notice Chainlink-compatible upkeep runner that invests all idle SFVault assets
 *         through SFStrategyAggregator using a UniV3-targeted payload.
 * @dev Rules for investment attempts:
 *      - full vault idle assets (`SFVault.idleAssets()`)
 *      - auto `otherRatioBPS` from current price + [tickLower, tickUpper]
 *      - Universal Router swap payloads with amountIn BPS sentinel
 * @dev Rules for rebalance attempts:
 *      - Observe the strategy on its own cadence, independent from invest cadence.
 *      - Record one sampled snapshot per check:
 *        - which side of the range the position is on (`in range`, `below`, `above`)
 *        - the current inventory split between underlying and `otherToken`
 *      - Rebalance through the `ordinary` path when the position is currently out of range and inventory
 *        has been 95/5 one-sided or worse for 24 consecutive observed hours.
 *      - Otherwise, rebalance through the `oscillation` path only when:
 *        - the position is currently out of range,
 *        - it has spent at least 18 observed hours of the last 72 hours on the same out-of-range side, and
 *        - inventory has been 80/20 one-sided or worse for 24 consecutive observed hours.
 *      - Both rebalance paths are additionally guarded by a peg check:
 *        - spot must be within 10 bps of peg, and
 *        - spot must be within 10 bps of a strict 30-minute TWAP.
 *      - When peg guard blocks an otherwise valid rebalance candidate, the upkeep also skips invest for
 *        that run so new capital is not deployed during an intentional depeg pause.
 * @dev Sampling and duration calculations are intentionally conservative. Time only accrues between adjacent
 *      samples that confirm the same condition, so an 18-hour oscillation threshold with a 12-hour cadence
 *      effectively requires 24 observed hours on-chain.
 */

pragma solidity 0.8.28;

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    Ownable2StepUpgradeable,
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "contracts/interfaces/helpers/INonfungiblePositionManager.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ISFStrategyMaintenance} from "contracts/interfaces/saveFunds/ISFStrategyMaintenance.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {LiquidityAmountsV3} from "contracts/helpers/uniswapHelpers/libraries/LiquidityAmountsV3.sol";
import {PositionReader} from "contracts/helpers/uniswapHelpers/libraries/PositionReader.sol";
import {TickMathV3} from "contracts/helpers/uniswapHelpers/libraries/TickMathV3.sol";
import {ISFVaultAutomation} from "contracts/helpers/chainlink/automation/interfaces/ISFVaultAutomation.sol";
import {
    ISFUniV3StrategyAutomationView
} from "contracts/helpers/chainlink/automation/interfaces/ISFUniV3StrategyAutomationView.sol";
import {
    ISFAggregatorAutomationView
} from "contracts/helpers/chainlink/automation/interfaces/ISFAggregatorAutomationView.sol";

/// @custom:oz-upgrades-from contracts/version_previous_contracts/SaveFundsInvestAutomationRunnerV1.sol:SaveFundsInvestAutomationRunnerV1
contract SaveFundsInvestAutomationRunner is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable
{
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant AMOUNT_IN_BPS_FLAG = 1 << 255;
    uint256 internal constant DAILY_INTERVAL = 12 hours;
    INonfungiblePositionManager internal constant POSITION_MANAGER =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    // Rebalance policy constants
    uint256 internal constant REBALANCE_CONSECUTIVE_TRIGGER = 24 hours;
    uint256 internal constant REBALANCE_OSCILLATION_SIDE_TRIGGER = 18 hours;
    uint256 internal constant REBALANCE_WINDOW = 3 days;
    uint32 internal constant REBALANCE_PEG_GUARD_TWAP_WINDOW = 30 minutes;
    uint16 internal constant REBALANCE_PEG_GUARD_BPS = 10;
    uint16 internal constant REBALANCE_ORDINARY_ONE_SIDED_BPS = 500;
    uint16 internal constant REBALANCE_OSCILLATION_ONE_SIDED_BPS = 2_000;
    uint8 internal constant REBALANCE_SAMPLE_CAP = 16;
    int24 internal constant REBALANCE_TICK_LOWER_OFFSET = -2;
    int24 internal constant REBALANCE_TICK_UPPER_OFFSET = 3;
    uint8 internal constant RANGE_SIDE_IN_RANGE = 0;
    uint8 internal constant RANGE_SIDE_BELOW = 1;
    uint8 internal constant RANGE_SIDE_ABOVE = 2;
    uint8 internal constant REBALANCE_PATH_NONE = 0;
    uint8 internal constant REBALANCE_PATH_ORDINARY = 1;
    uint8 internal constant REBALANCE_PATH_OSCILLATION = 2;

    IAddressManager public addressManager;
    ISFVaultAutomation public vault;
    address public aggregator;
    address public uniStrategy;
    IUniswapV3Pool public pool;
    address public underlyingToken;
    address public otherToken;
    bool public otherIsToken0;

    uint256 public interval;
    uint256 public lastRun;
    uint256 public minIdleAssets;

    bool public testMode;
    bool public skipIfPaused;
    bool public strictUniOnlyAllocation;
    bool public useAutoOtherRatio;

    uint16 public manualOtherRatioBPS;
    uint16 public swapToOtherBPS;
    uint16 public swapToUnderlyingBPS;

    uint256 public deadlineBuffer;
    uint256 public minUnderlying;
    uint256 public minOther;

    uint256 public rebalanceCheckInterval;
    uint256 public lastRebalanceCheck;
    uint256 public lastSuccessfulRebalance; // Bookkeeping only
    bool public rebalanceEnabled;
    uint8 internal rebalanceSampleCount;
    uint8 internal rebalanceSampleHead;

    // Fixed-size ring buffer used for conservative sampled history.
    // Each index represents one observation timestamp and its associated state snapshot.
    uint40[REBALANCE_SAMPLE_CAP] internal rebalanceSampleTimestamps;
    bool[REBALANCE_SAMPLE_CAP] internal rebalanceSampleOutOfRange;
    uint8[REBALANCE_SAMPLE_CAP] internal rebalanceSampleRangeSides;
    uint16[REBALANCE_SAMPLE_CAP] internal rebalanceSampleInventoryOtherRatioBPS;

    /// @dev One sampled rebalance snapshot. "What do we see right now?"
    struct RebalanceObservation {
        uint8 rangeSide;
        int24 currentTick;
        uint16 inventoryOtherRatioBPS;
    }

    /// @dev Current peg-guard diagnostics. Written when rebalance is blocked, helps to know if it was an absolute depeg or spot-vs-TWAP divergence.
    ///
    struct PegGuardStatus {
        bool passed;
        uint16 spotPegDeviationBPS;
        uint16 spotVsTwapDeviationBPS;
    }

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnUpkeepSkippedPaused(uint256 ts);
    event OnUpkeepSkippedLowIdle(uint256 ts, uint256 idleAssets, uint256 minIdleAssets);
    event OnUpkeepSkippedAllocation(uint256 ts);
    event OnUpkeepAttempt(uint256 ts, uint256 idleAssets, uint16 otherRatioBPS, bytes32 bundleHash);
    event OnInvestSucceeded(uint256 ts, uint256 requestedAssets, uint256 investedAssets, uint16 otherRatioBPS);
    event OnInvestFailed(uint256 ts, bytes reason);
    event OnRebalanceAttempt(
        uint256 ts, int24 currentTick, int24 newTickLower, int24 newTickUpper, uint16 otherRatioBPS, bytes32 bundleHash
    );
    event OnRebalanceSucceeded(
        uint256 ts, int24 currentTick, int24 newTickLower, int24 newTickUpper, uint16 otherRatioBPS
    );
    event OnRebalanceFailed(
        uint256 ts, int24 currentTick, int24 newTickLower, int24 newTickUpper, uint16 otherRatioBPS, bytes reason
    );

    error SaveFundsInvestAutomationRunner__NotAddressZero();
    error SaveFundsInvestAutomationRunner__TooSmall();
    error SaveFundsInvestAutomationRunner__OutOfRange();
    error SaveFundsInvestAutomationRunner__BadPoolConfig();
    error SaveFundsInvestAutomationRunner__BadStrategyConfig();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _vault,
        address _aggregator,
        address _uniStrategy,
        address _addressManager,
        uint256 _intervalSeconds,
        uint256 _minIdleAssets,
        address _owner
    ) external initializer {
        __UUPSUpgradeable_init();
        __Ownable2Step_init();
        __Ownable_init(_owner);
        __Pausable_init();

        require(
            _vault != address(0) && _aggregator != address(0) && _uniStrategy != address(0)
                && _addressManager != address(0),
            SaveFundsInvestAutomationRunner__NotAddressZero()
        );
        require(
            _intervalSeconds == 0 || _intervalSeconds >= DAILY_INTERVAL, SaveFundsInvestAutomationRunner__TooSmall()
        );

        vault = ISFVaultAutomation(_vault);
        aggregator = _aggregator;
        uniStrategy = _uniStrategy;
        addressManager = IAddressManager(_addressManager);

        address pool_ = ISFUniV3StrategyAutomationView(_uniStrategy).pool();
        address underlying_ = ISFUniV3StrategyAutomationView(_uniStrategy).asset();
        address other_ = ISFUniV3StrategyAutomationView(_uniStrategy).otherToken();
        require(
            pool_ != address(0) && underlying_ != address(0) && other_ != address(0),
            SaveFundsInvestAutomationRunner__BadStrategyConfig()
        );

        pool = IUniswapV3Pool(pool_);
        underlyingToken = underlying_;
        otherToken = other_;

        address token0 = IUniswapV3Pool(pool_).token0();
        address token1 = IUniswapV3Pool(pool_).token1();
        require(
            (token0 == underlying_ && token1 == other_) || (token0 == other_ && token1 == underlying_),
            SaveFundsInvestAutomationRunner__BadPoolConfig()
        );

        otherIsToken0 = token0 == other_;

        interval = _intervalSeconds == 0 ? DAILY_INTERVAL : _intervalSeconds;
        minIdleAssets = _minIdleAssets;
        lastRun = 0;

        testMode = false;
        skipIfPaused = true;
        strictUniOnlyAllocation = true;
        useAutoOtherRatio = true;

        manualOtherRatioBPS = 0;
        swapToOtherBPS = uint16(MAX_BPS);
        swapToUnderlyingBPS = uint16(MAX_BPS);

        deadlineBuffer = 0;
        minUnderlying = 0;
        minOther = 0;
    }

    /// @custom:oz-upgrades-validate-as-initializer
    function initializeV2() external reinitializer(2) onlyOwner {
        _initializeRebalanceState();
    }

    /*//////////////////////////////////////////////////////////////
                                SETTINGS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Accepts the proposed `KEEPER` role in the address manager.
     * @dev Callable by anyone. The call only succeeds when the runner was previously proposed
     *      as the new holder for `Roles.KEEPER`.
     */
    function acceptKeeperRole() external {
        addressManager.acceptProposedRole(Roles.KEEPER);
    }

    /**
     * @notice Sets the execution interval for upkeep runs.
     * @dev Restricted to owner. Minimum allowed value is 12 hours unless `testMode` is enabled.
     * @param newIntervalSeconds New interval in seconds.
     */
    function setInterval(uint256 newIntervalSeconds) external onlyOwner {
        require(
            newIntervalSeconds >= DAILY_INTERVAL || (testMode && newIntervalSeconds > 0),
            SaveFundsInvestAutomationRunner__TooSmall()
        );
        interval = newIntervalSeconds;
    }

    /**
     * @notice Sets the cadence used to observe out-of-range conditions for rebalance.
     * @dev Uses the same minimum interval guard as invest cadence unless `testMode` is enabled.
     * @param newIntervalSeconds New rebalance observation interval in seconds.
     */
    function setRebalanceCheckInterval(uint256 newIntervalSeconds) external onlyOwner {
        require(
            newIntervalSeconds >= DAILY_INTERVAL || (testMode && newIntervalSeconds > 0),
            SaveFundsInvestAutomationRunner__TooSmall()
        );
        rebalanceCheckInterval = newIntervalSeconds;
    }

    /**
     * @notice Toggles test mode.
     * @dev Test mode allows shorter configured intervals for local and fork testing.
     */
    function toggleTestMode() external onlyOwner {
        testMode = !testMode;
    }

    /**
     * @notice Sets the minimum idle-assets threshold required to trigger investment.
     * @param newMinIdleAssets Minimum idle asset threshold in underlying units.
     */
    function setMinIdleAssets(uint256 newMinIdleAssets) external onlyOwner {
        minIdleAssets = newMinIdleAssets;
    }

    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    function unpause() external onlyOwner whenPaused {
        _unpause();
    }

    /**
     * @notice Toggles dependency paused-state checks during upkeep.
     * @dev When enabled, the runner skips work if the vault, aggregator, or strategy is paused.
     */
    function toggleSkipIfPaused() external onlyOwner whenNotPaused {
        skipIfPaused = !skipIfPaused;
    }

    /**
     * @notice Toggles strict allocation mode that requires Uni strategy to be the only active allocation.
     * @dev This protects the existing single-strategy bundle builder from being used when the
     *      aggregator is configured to route capital elsewhere.
     */
    function toggleStrictUniOnlyAllocation() external onlyOwner whenNotPaused {
        strictUniOnlyAllocation = !strictUniOnlyAllocation;
    }

    /**
     * @notice Toggles the rebalance branch of the upkeep.
     * @dev Invest automation remains available even when rebalance automation is disabled.
     */
    function toggleRebalanceEnabled() external onlyOwner whenNotPaused {
        rebalanceEnabled = !rebalanceEnabled;
    }

    /**
     * @notice Toggles automatic ratio computation for invest payloads.
     * @dev When disabled, `manualOtherRatioBPS` is used for both preview and invest execution.
     */
    function setUseAutoOtherRatio() external onlyOwner whenNotPaused {
        useAutoOtherRatio = !useAutoOtherRatio;
    }

    /**
     * @notice Sets manual `otherRatioBPS` used when auto ratio is disabled.
     * @param bps Target ratio for other token in BPS (0..10000).
     */
    function setManualOtherRatioBPS(uint16 bps) external onlyOwner whenNotPaused {
        require(bps <= MAX_BPS, SaveFundsInvestAutomationRunner__OutOfRange());
        manualOtherRatioBPS = bps;
    }

    /**
     * @notice Sets swap BPS sentinels used to build swap payloads.
     * @param swapToOtherBPS_ BPS for underlying->other swap sentinel (0..10000).
     * @param swapToUnderlyingBPS_ BPS for other->underlying swap sentinel (0..10000).
     */
    function setSwapBPS(uint16 swapToOtherBPS_, uint16 swapToUnderlyingBPS_) external onlyOwner whenNotPaused {
        require(
            swapToOtherBPS_ <= MAX_BPS && swapToUnderlyingBPS_ <= MAX_BPS, SaveFundsInvestAutomationRunner__OutOfRange()
        );
        swapToOtherBPS = swapToOtherBPS_;
        swapToUnderlyingBPS = swapToUnderlyingBPS_;
    }

    /**
     * @notice Sets minimum amounts for position manager actions.
     * @param minUnderlying_ Minimum underlying amount for PM operations.
     * @param minOther_ Minimum other-token amount for PM operations.
     */
    function setPositionMins(uint256 minUnderlying_, uint256 minOther_) external onlyOwner whenNotPaused {
        minUnderlying = minUnderlying_;
        minOther = minOther_;
    }

    /**
     * @notice Sets a deadline buffer for position manager actions.
     * @param deadlineBuffer_ Buffer in seconds added to `block.timestamp` for PM deadlines.
     */
    function setDeadlineBuffer(uint256 deadlineBuffer_) external onlyOwner whenNotPaused {
        deadlineBuffer = deadlineBuffer_;
    }

    /**
     * @notice Manually sets `lastRun`.
     * @dev Useful for operational recovery and scheduling adjustments.
     * @param ts New timestamp to store as `lastRun`.
     */
    function setLastRun(uint256 ts) external onlyOwner {
        lastRun = ts;
    }

    /**
     * @notice Manually seeds the latest successful rebalance timestamp.
     * @dev This no longer participates in trigger gating, but it remains useful for operator
     *      bookkeeping and continuity when migrating an already-operated strategy.
     * @param ts Timestamp to store as the latest successful rebalance time.
     */
    function setLastSuccessfulRebalance(uint256 ts) external onlyOwner {
        lastSuccessfulRebalance = ts;
    }

    /*//////////////////////////////////////////////////////////////
                            KEEPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Chainlink Automation fallback function.
     * @dev This function is intentionally conservative: it only reports upkeep when either
     *      an invest attempt or a rebalance observation is currently actionable.
     *      The rebalance half just answers "should we sample now?" so the write path can
     *      recompute from live state.
     *      It does not revert if dependencies are paused or temporarily unavailable.
     * @return upkeepNeeded True when upkeep should be executed.
     * @return performData ABI-encoded `(idleAssets, investNeeded, rebalanceCheckNeeded)`.
     */
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        if (paused()) return (false, bytes(""));

        if (skipIfPaused) {
            if (_isPaused(address(vault)) || _isPaused(aggregator) || _isPaused(uniStrategy)) {
                return (false, bytes(""));
            }
        }

        uint256 idle;
        bool investWindowOpen = _isInvestWindowOpen();
        bool investNeeded;

        if (investWindowOpen) {
            // Keep the current invest safety checks in the read path so performUpkeep
            // only wakes up when the bundle is expected to be usable.
            if (strictUniOnlyAllocation && !_isUniOnlyAllocation()) {
                investNeeded = false;
            } else {
                try vault.idleAssets() returns (uint256 assets) {
                    idle = assets;
                    investNeeded = idle != 0 && idle >= minIdleAssets;
                } catch {
                    investNeeded = false;
                }
            }
        }

        // Rebalance checks run independently from invest cadence so the runner can keep
        // sampling out-of-range history even when no idle capital is available.
        bool rebalanceCheckNeeded = _shouldCheckRebalance();
        if (!investNeeded && !rebalanceCheckNeeded) return (false, bytes(""));

        performData = abi.encode(idle, investNeeded, rebalanceCheckNeeded);
        return (true, performData);
    }

    /**
     * @notice Executes the runner's upkeep actions.
     * @dev Rebalance work is attempted before invest work so any new capital is deployed into
     *      the fresh tick range instead of the stale one. The input payload is ignored because
     *      the contract recomputes all safety checks at execution time.
     *      The execution order is:
     *      1. optionally sample and evaluate rebalance
     *      2. stop entirely if rebalance failed or peg guard intentionally blocked it
     *      3. only then continue into the normal invest flow
     */
    function performUpkeep(bytes calldata) external {
        if (paused()) return;

        bool investWindowOpen = _isInvestWindowOpen();
        bool rebalanceCheckNeeded = _shouldCheckRebalance();
        if (!investWindowOpen && !rebalanceCheckNeeded) return;

        if (skipIfPaused) {
            if (_isPaused(address(vault)) || _isPaused(aggregator) || _isPaused(uniStrategy)) {
                // Advance the relevant clocks.
                if (rebalanceCheckNeeded) lastRebalanceCheck = block.timestamp;
                if (investWindowOpen) lastRun = block.timestamp;
                emit OnUpkeepSkippedPaused(block.timestamp);
                return;
            }
        }

        // Rebalance failure short-circuits the upkeep so the runner does not add new capital into a position it just failed to move.
        if (rebalanceCheckNeeded && _observeAndMaybeRebalance()) return;

        if (!investWindowOpen) return;

        if (strictUniOnlyAllocation && !_isUniOnlyAllocation()) {
            lastRun = block.timestamp;
            emit OnUpkeepSkippedAllocation(block.timestamp);
            return;
        }

        uint256 idle;
        try vault.idleAssets() returns (uint256 assets) {
            idle = assets;
        } catch {
            return;
        }

        if (idle == 0 || idle < minIdleAssets) {
            emit OnUpkeepSkippedLowIdle(block.timestamp, idle, minIdleAssets);
            return;
        }

        lastRun = block.timestamp;

        uint16 otherRatioBPS_ = useAutoOtherRatio ? _resolveAutoOtherRatioBPS(idle) : manualOtherRatioBPS;
        bytes memory uniPayload = _buildUniV3Payload(otherRatioBPS_);
        (address[] memory strategies, bytes[] memory payloads, bytes memory bundle) =
            _buildSingleStrategyBundle(uniPayload);
        emit OnUpkeepAttempt(block.timestamp, idle, otherRatioBPS_, keccak256(bundle));

        try vault.investIntoStrategy(idle, strategies, payloads) returns (uint256 investedAssets) {
            emit OnInvestSucceeded(block.timestamp, idle, investedAssets, otherRatioBPS_);
        } catch (bytes memory reason) {
            emit OnInvestFailed(block.timestamp, reason);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            GETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Builds a preview of the strategy bundle currently produced by this runner.
     * @dev Purely view helper; does not mutate state.
     * @param assetsIncoming Amount treated as incoming underlying when computing auto ratio.
     * @return otherRatioBPS_ Final selected ratio in BPS.
     * @return strategies Strategy array to pass into vault invest.
     * @return payloads Per-strategy payload array to pass into vault invest.
     * @return bundle ABI-encoded `(strategies, payloads)` bundle.
     */
    function previewInvestBundle(uint256 assetsIncoming)
        external
        view
        returns (uint16 otherRatioBPS_, address[] memory strategies, bytes[] memory payloads, bytes memory bundle)
    {
        otherRatioBPS_ = useAutoOtherRatio ? _resolveAutoOtherRatioBPS(assetsIncoming) : manualOtherRatioBPS;
        bytes memory uniPayload = _buildUniV3Payload(otherRatioBPS_);
        (strategies, payloads, bundle) = _buildSingleStrategyBundle(uniPayload);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Builds UniV3 action payload expected by the strategy.
     * @dev Encoding matches strategy schema:
     *      `abi.encode(uint16, bytes, bytes, uint256, uint256, uint256)`.
     * @param _otherRatioBPS Target ratio in BPS.
     * @return ABI-encoded UniV3 action payload.
     */
    function _buildUniV3Payload(uint16 _otherRatioBPS) internal view returns (bytes memory) {
        bytes memory _swapToOtherData = _buildSingleHopSwapData(underlyingToken, otherToken, swapToOtherBPS);
        bytes memory _swapToUnderlyingData = _buildSingleHopSwapData(otherToken, underlyingToken, swapToUnderlyingBPS);

        // A zero deadline keeps compatibility with the strategy's own default deadline logic.
        uint256 _pmDeadline = deadlineBuffer == 0 ? 0 : block.timestamp + deadlineBuffer;

        return abi.encode(_otherRatioBPS, _swapToOtherData, _swapToUnderlyingData, _pmDeadline, minUnderlying, minOther);
    }

    /**
     * @notice Wraps a single strategy payload into the aggregator bundle format.
     * @dev The runner currently targets a single UniV3 strategy, so both arrays have length one.
     * @param _payload Strategy-specific calldata payload.
     * @return strategies Strategy array expected by the vault.
     * @return payloads Payload array expected by the vault.
     * @return bundle ABI-encoded `(strategies, payloads)` wrapper.
     */
    function _buildSingleStrategyBundle(bytes memory _payload)
        internal
        view
        returns (address[] memory strategies, bytes[] memory payloads, bytes memory bundle)
    {
        strategies = new address[](1);
        strategies[0] = uniStrategy;

        payloads = new bytes[](1);
        payloads[0] = _payload;

        bundle = abi.encode(strategies, payloads);
    }

    /**
     * @notice Builds one-hop Universal Router swap data with BPS sentinel amount.
     * @dev Returns empty bytes when `bps_ == 0`.
     * @param _tokenIn Input token.
     * @param _tokenOut Output token.
     * @param _bps BPS sentinel for runtime amount calculation.
     * @return ABI-encoded `(bytes[] inputs, uint256 deadline)` swap payload.
     */
    function _buildSingleHopSwapData(address _tokenIn, address _tokenOut, uint16 _bps)
        internal
        view
        returns (bytes memory)
    {
        if (_bps == 0) return bytes("");

        // The swap path is always a single pool hop because the strategy payload mirrors
        // the existing manual automation scripts.
        bytes memory _path = abi.encodePacked(_tokenIn, pool.fee(), _tokenOut);
        uint256 _amountIn = AMOUNT_IN_BPS_FLAG | uint256(_bps);
        bytes memory _input = abi.encode(uniStrategy, _amountIn, uint256(0), _path, true);

        bytes[] memory _inputs = new bytes[](1);
        _inputs[0] = _input;

        // deadline=0 -> strategy replaces with (block.timestamp + DEFAULT_SWAP_DEADLINE)
        return abi.encode(_inputs, uint256(0));
    }

    /**
     * @notice Resolves auto `otherRatioBPS` from live pool/strategy state.
     * @dev Uses spot `slot0` price as primary path and falls back to strategy TWAP/spot valuation
     *      helper only if spot read is unexpectedly zero. Applies 1 bps cleanup nudge when
     *      computed ratio is 0 but other-token value is non-trivial.
     * @param _assetsIncoming Incoming underlying amount considered in ratio adjustment.
     * @return ratioBPS Final ratio in BPS.
     */
    function _resolveAutoOtherRatioBPS(uint256 _assetsIncoming) internal view returns (uint16) {
        (int24 _tickLower, int24 _tickUpper) = _currentStrategyTicks();
        return _resolveAutoOtherRatioBPSForRange(_assetsIncoming, _tickLower, _tickUpper);
    }

    /**
     * @notice Resolves the auto ratio for an arbitrary target range.
     * @dev Used by invest for the current range and by rebalance for the candidate next range.
     *      This is intentionally separate from the rebalance inventory sampling ratio:
     *      - inventory sampling asks "how one-sided is the strategy right now?"
     *      - auto ratio asks "what mix should a fresh position target for this range?"
     * @param _assetsIncoming Incoming underlying amount considered in ratio adjustment.
     * @param _tickLower Lower tick of the target range.
     * @param _tickUpper Upper tick of the target range.
     * @return Ratio of the non-underlying token in BPS.
     */
    function _resolveAutoOtherRatioBPSForRange(uint256 _assetsIncoming, int24 _tickLower, int24 _tickUpper)
        internal
        view
        returns (uint16)
    {
        (uint160 _spotSqrtPriceX96,,,,,,) = pool.slot0();
        uint160 _ratioSqrtPriceX96 = _spotSqrtPriceX96;
        if (_ratioSqrtPriceX96 == 0) {
            // Spot should be the normal path. TWAP only exists as a defensive fallback when slot0 returns an unusable zero price.
            uint32 _window = ISFUniV3StrategyAutomationView(uniStrategy).twapWindow();
            _ratioSqrtPriceX96 = _valuationSqrtPriceX96(_window);
        }

        uint16 _ratioBPS = _computeOtherRatioBPS(_ratioSqrtPriceX96, _tickLower, _tickUpper);

        // If LP-optimal ratio is 0 but strategy already has meaningful otherToken value,
        // force 1 bps so strategy can perform cleanup toward underlying when needed.
        if (_ratioBPS == 0) {
            uint160 _cleanupSqrtPriceX96 = _spotSqrtPriceX96 == 0 ? _ratioSqrtPriceX96 : _spotSqrtPriceX96;
            uint256 _underlyingBal = IERC20(underlyingToken).balanceOf(uniStrategy) + _assetsIncoming;
            uint256 _otherBal = IERC20(otherToken).balanceOf(uniStrategy);
            uint256 _otherValueInUnderlying = _quoteOtherAsUnderlyingAtSqrtPrice(_otherBal, _cleanupSqrtPriceX96);

            uint256 _totalValueInUnderlying = _underlyingBal + _otherValueInUnderlying;
            if (_totalValueInUnderlying > 0) {
                uint256 _currentOtherRatioBPS = Math.mulDiv(_otherValueInUnderlying, MAX_BPS, _totalValueInUnderlying);
                if (_currentOtherRatioBPS >= 1) _ratioBPS = 1;
            }
        }

        return _ratioBPS;
    }

    /**
     * @notice Records the latest rebalance observation and executes rebalance when rules are met.
     * @dev Returns `true` when the upkeep should stop before the invest branch. That includes
     *      both a failed rebalance attempt and a rebalance candidate blocked by peg guard.
     *      The evaluation flow is:
     *      1. sample current range side + inventory ratio
     *      2. update the ring buffer
     *      3. measure ordinary-path and oscillation-path durations from sampled history
     *      4. choose the trigger path, if any
     *      5. apply peg guard only after a path is otherwise valid
     *      6. execute rebalance if the path survives peg guard
     * @return skipInvest_ True when the caller should skip the invest branch for this upkeep.
     */
    function _observeAndMaybeRebalance() internal returns (bool skipInvest_) {
        lastRebalanceCheck = block.timestamp;

        // Sample the live range side and inventory composition first so all downstream decisions
        // are made from the exact same observation.
        RebalanceObservation memory _observation = _currentRebalanceObservation();
        _recordRebalanceSample(_observation.rangeSide, _observation.inventoryOtherRatioBPS);

        // Ordinary path: 24h consecutive 95/5-or-worse inventory while out of range.
        uint256 _ordinaryInventoryObserved = _consecutiveInventoryOneSidedObserved(REBALANCE_ORDINARY_ONE_SIDED_BPS);
        // Oscillation path: 24h consecutive 80/20-or-worse inventory plus same-side history inside 72h.
        uint256 _oscillationInventoryObserved =
            _consecutiveInventoryOneSidedObserved(REBALANCE_OSCILLATION_ONE_SIDED_BPS);
        uint256 _sameSideObserved = _rollingSameSideObserved(_observation.rangeSide, block.timestamp - REBALANCE_WINDOW);

        uint8 _triggerPath = _rebalanceTriggerPath(
            _observation.rangeSide, _ordinaryInventoryObserved, _sameSideObserved, _oscillationInventoryObserved
        );

        // Peg guard is only meaningful once a path already qualifies.
        PegGuardStatus memory _pegGuard;
        if (_triggerPath != REBALANCE_PATH_NONE) _pegGuard = _evaluatePegGuard();
        if (_triggerPath == REBALANCE_PATH_NONE) return false;

        if (!_pegGuard.passed) {
            // This is an intentional skip. Still stop the investment because the rebalance was considered unsafe due to peg conditions.
            return true;
        }

        // Compute the next band from the live monitoring tick, then reuse the invest ratio
        // math so the rebalance mints into the new band with the same capital-efficiency logic.
        (int24 _newTickLower, int24 _newTickUpper) = _computeRebalanceTicks(_observation.currentTick);
        uint16 _otherRatioBPS = _resolveAutoOtherRatioBPSForRange(0, _newTickLower, _newTickUpper);
        bytes memory _rebalancePayload = abi.encode(_newTickLower, _newTickUpper, _buildUniV3Payload(_otherRatioBPS));
        (,, bytes memory _bundle) = _buildSingleStrategyBundle(_rebalancePayload);

        emit OnRebalanceAttempt(
            block.timestamp, _observation.currentTick, _newTickLower, _newTickUpper, _otherRatioBPS, keccak256(_bundle)
        );

        try ISFStrategyMaintenance(aggregator).rebalance(_bundle) {
            lastSuccessfulRebalance = block.timestamp;
            _clearRebalanceSamples();
            emit OnRebalanceSucceeded(
                block.timestamp, _observation.currentTick, _newTickLower, _newTickUpper, _otherRatioBPS
            );
        } catch (bytes memory reason) {
            skipInvest_ = true;
            emit OnRebalanceFailed(
                block.timestamp, _observation.currentTick, _newTickLower, _newTickUpper, _otherRatioBPS, reason
            );
        }
    }

    /**
     * @notice Determines whether a new rebalance observation should be sampled now.
     * @dev The runner keeps sampling while the position is currently out of range or when there
     *      is recent out-of-range history inside the rolling window.
     *      That second branch is what lets the oscillation rule continue accumulating evidence
     *      even after the price briefly returns inside the band.
     * @return True when the rebalance observer should run.
     */
    function _shouldCheckRebalance() internal view returns (bool) {
        if (!rebalanceEnabled) return false;
        if (block.timestamp < lastRebalanceCheck + rebalanceCheckInterval) return false;

        // Continue sampling after the position comes back in range so the oscillation rule
        // can still be evaluated from recent history.
        (uint8 _rangeSide,,,) = _currentRangeStatus();
        if (_rangeSide != RANGE_SIDE_IN_RANGE) return true;

        return _hasRecentOutOfRangeSample(block.timestamp - REBALANCE_WINDOW);
    }

    /**
     * @notice Returns the current range state for the UniV3 strategy.
     * @dev Uses the monitoring tick source rather than the raw spot tick directly so the same
     *      fallback logic is shared everywhere the runner reasons about range status.
     *      The upper bound is exclusive, matching Uniswap V3's active-liquidity interval `[lower, upper)`.
     * @return rangeSide_ Encoded range side: 0=in range, 1=below lower, 2=above/equal upper.
     * @return currentTick_ Tick used for the range check.
     * @return tickLower_ Current strategy lower tick.
     * @return tickUpper_ Current strategy upper tick.
     */
    function _currentRangeStatus()
        internal
        view
        returns (uint8 rangeSide_, int24 currentTick_, int24 tickLower_, int24 tickUpper_)
    {
        (tickLower_, tickUpper_) = _currentStrategyTicks();
        currentTick_ = _currentMonitoringTick();
        rangeSide_ = _rangeSideForTick(currentTick_, tickLower_, tickUpper_);
    }

    /**
     * @notice Reads the current strategy ticks from the UniV3 strategy.
     * @return tickLower_ Current lower tick.
     * @return tickUpper_ Current upper tick.
     */
    function _currentStrategyTicks() internal view returns (int24 tickLower_, int24 tickUpper_) {
        tickLower_ = ISFUniV3StrategyAutomationView(uniStrategy).tickLower();
        tickUpper_ = ISFUniV3StrategyAutomationView(uniStrategy).tickUpper();
    }

    /**
     * @notice Returns the tick used by the runner for range monitoring decisions.
     * @dev Prefers the live spot tick. If spot price is unexpectedly unavailable, it derives a
     *      fallback tick from the strategy valuation price path.
     * @return tick_ Tick used for monitoring and rebalance band calculation.
     */
    function _currentMonitoringTick() internal view returns (int24 tick_) {
        (uint160 _spotSqrtPriceX96, int24 _spotTick,,,,,) = pool.slot0();
        tick_ = _spotTick;

        if (_spotSqrtPriceX96 != 0) return tick_;

        // Fallback to valuation price only when spot is unusable.
        uint32 _window = ISFUniV3StrategyAutomationView(uniStrategy).twapWindow();
        uint160 _fallbackSqrtPriceX96 = _valuationSqrtPriceX96(_window);
        if (_fallbackSqrtPriceX96 != 0) tick_ = TickMathV3.getTickAtSqrtRatio(_fallbackSqrtPriceX96);
    }

    /**
     * @notice Computes the next rebalance band from the current monitoring tick.
     * @dev Applies the `-2 / +3` offsets and then snaps them to pool tick spacing.
     * @param _currentTick Current monitoring tick.
     * @return newTickLower_ Lower tick for the next position.
     * @return newTickUpper_ Upper tick for the next position.
     */
    function _computeRebalanceTicks(int24 _currentTick)
        internal
        view
        returns (int24 newTickLower_, int24 newTickUpper_)
    {
        int24 _spacing = pool.tickSpacing();
        newTickLower_ = _floorToSpacing(SafeCast.toInt24(int256(_currentTick) + REBALANCE_TICK_LOWER_OFFSET), _spacing);
        newTickUpper_ = _ceilToSpacing(SafeCast.toInt24(int256(_currentTick) + REBALANCE_TICK_UPPER_OFFSET), _spacing);
    }

    /**
     * @notice Builds the current rebalance observation snapshot.
     * @dev This is the single source of truth for "what did we observe this check?" and is used
     *      both for storage and for any immediate rebalance decision derived from that.
     * @return observation_ Current range side, monitoring tick, and inventory ratio.
     */
    function _currentRebalanceObservation() internal view returns (RebalanceObservation memory observation_) {
        (observation_.rangeSide, observation_.currentTick,,) = _currentRangeStatus();
        observation_.inventoryOtherRatioBPS = _currentInventoryOtherRatioBPS();
    }

    /**
     * @notice Stores one rebalance observation in the fixed-size ring buffer.
     * @dev New samples overwrite the oldest entries once the buffer reaches capacity.
     *      The parallel arrays deliberately duplicate `outOfRange` and `rangeSide` because:
     *      - `outOfRange` is a cheap coarse filter for "do we have any recent history?"
     *      - `rangeSide` is needed for oscillation's same-side rule
     * @param _rangeSide Encoded range side for the observation.
     * @param _inventoryOtherRatioBPS Share of total strategy value held in `otherToken`.
     */
    function _recordRebalanceSample(uint8 _rangeSide, uint16 _inventoryOtherRatioBPS) internal {
        rebalanceSampleTimestamps[rebalanceSampleHead] = uint40(block.timestamp);
        rebalanceSampleOutOfRange[rebalanceSampleHead] = _rangeSide != RANGE_SIDE_IN_RANGE;
        rebalanceSampleRangeSides[rebalanceSampleHead] = _rangeSide;
        rebalanceSampleInventoryOtherRatioBPS[rebalanceSampleHead] = _inventoryOtherRatioBPS;

        rebalanceSampleHead = uint8((uint256(rebalanceSampleHead) + 1) % REBALANCE_SAMPLE_CAP);
        if (rebalanceSampleCount < REBALANCE_SAMPLE_CAP) ++rebalanceSampleCount;
    }

    /**
     * @notice Clears the active rebalance sample window after a successful rebalance.
     * @dev The old array contents are intentionally left in storage; only the active ring-buffer
     *      head and count are reset. This makes the next rebalance cycle start from fresh observations
     *      without paying to zero every historical slot again.
     */
    function _clearRebalanceSamples() internal {
        rebalanceSampleCount = 0;
        rebalanceSampleHead = 0;
    }

    /**
     * @notice Computes the latest consecutive duration of one-sided inventory.
     * @dev The duration is based on sampled observations, not continuous oracle history.
     *      It only measures the most recent streak ending at the latest sample, which is exactly
     *      what the ordinary path and the inventory half of the oscillation path need.
     * @param _oneSidedThresholdBPS BPS threshold that defines one-sided inventory.
     * @return duration_ Observed consecutive time with one-sided inventory.
     */
    function _consecutiveInventoryOneSidedObserved(uint16 _oneSidedThresholdBPS)
        internal
        view
        returns (uint256 duration_)
    {
        if (rebalanceSampleCount == 0) return 0;

        uint256 _latestIndex = _sampleIndexFromNewest(0);
        uint16 _latestRatio = rebalanceSampleInventoryOtherRatioBPS[_latestIndex];
        if (!_isInventoryOneSided(_latestRatio, _oneSidedThresholdBPS)) return 0;

        uint256 _latestTs = uint256(rebalanceSampleTimestamps[_latestIndex]);
        uint256 _earliestTs = _latestTs;

        // Walk backward until the first sample that is not one-sided enough for the requested threshold.
        for (uint256 offset = 1; offset < rebalanceSampleCount; ++offset) {
            uint256 _idx = _sampleIndexFromNewest(offset);
            if (!_isInventoryOneSided(rebalanceSampleInventoryOtherRatioBPS[_idx], _oneSidedThresholdBPS)) break;
            _earliestTs = uint256(rebalanceSampleTimestamps[_idx]);
        }

        return _latestTs - _earliestTs;
    }

    /**
     * @notice Computes sampled time spent on the same out-of-range side inside a rolling window.
     * @dev Only intervals bounded by two consecutive samples on the same non-zero side are counted.
     *      With the default 12-hour cadence, this means the 18-hour policy threshold will only
     *      be reached once 24 hours have been observed on-chain.
     * @param _rangeSide Range side to count for.
     * @param _windowStart Start timestamp of the rolling window.
     * @return duration_ Observed same-side out-of-range duration inside the window.
     */
    function _rollingSameSideObserved(uint8 _rangeSide, uint256 _windowStart)
        internal
        view
        returns (uint256 duration_)
    {
        if (_rangeSide == RANGE_SIDE_IN_RANGE || rebalanceSampleCount < 2) return 0;

        uint256 _previousTs;
        uint8 _previousSide;

        // Check oldest-to-newest so each pair of samples contributes at most once.
        for (uint256 i; i < rebalanceSampleCount; ++i) {
            uint256 _idx = _sampleIndexFromOldest(i);
            uint256 _ts = uint256(rebalanceSampleTimestamps[_idx]);
            uint8 _side = rebalanceSampleRangeSides[_idx];

            if (i != 0 && _previousSide == _rangeSide && _side == _rangeSide && _ts > _windowStart) {
                uint256 _intervalStart = _previousTs > _windowStart ? _previousTs : _windowStart;
                if (_ts > _intervalStart) duration_ += _ts - _intervalStart;
            }

            _previousTs = _ts;
            _previousSide = _side;
        }
    }

    /**
     * @notice Checks whether the buffer still contains a recent out-of-range observation.
     * @param _windowStart Earliest timestamp that is considered recent.
     * @return True when at least one out-of-range sample falls inside the window.
     */
    function _hasRecentOutOfRangeSample(uint256 _windowStart) internal view returns (bool) {
        for (uint256 i; i < rebalanceSampleCount; ++i) {
            uint256 _idx = _sampleIndexFromOldest(i);
            if (rebalanceSampleOutOfRange[_idx] && uint256(rebalanceSampleTimestamps[_idx]) >= _windowStart) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Resolves the storage index of a sample counted back from the newest entry.
     * @param _offset Number of samples back from the newest entry.
     * @return idx_ Physical ring-buffer index.
     */
    function _sampleIndexFromNewest(uint256 _offset) internal view returns (uint256 idx_) {
        uint256 _head = rebalanceSampleHead;
        idx_ = (_head + REBALANCE_SAMPLE_CAP - 1 - _offset) % REBALANCE_SAMPLE_CAP;
    }

    /**
     * @notice Resolves the storage index of a sample counted forward from the oldest entry.
     * @param _offset Number of samples forward from the oldest entry.
     * @return idx_ Physical ring-buffer index.
     */
    function _sampleIndexFromOldest(uint256 _offset) internal view returns (uint256 idx_) {
        uint256 _oldest = rebalanceSampleCount == REBALANCE_SAMPLE_CAP ? rebalanceSampleHead : 0;
        idx_ = (_oldest + _offset) % REBALANCE_SAMPLE_CAP;
    }

    /**
     * @notice Chooses which rebalance path, if any, is currently active.
     * @dev The path ordering is intentional:
     *      - ordinary wins first and bypasses oscillation once 95/5 one-sided for 24h
     *      - oscillation is only considered when ordinary is not already valid
     * @param _rangeSide Current range side.
     * @param _ordinaryInventoryObserved Consecutive observed time with 95/5-or-worse inventory.
     * @param _sameSideObserved Observed same-side out-of-range duration inside the 72-hour window.
     * @param _oscillationInventoryObserved Consecutive observed time with 80/20-or-worse inventory.
     * @return triggerPath_ Encoded path: 0=none, 1=ordinary, 2=oscillation.
     */
    function _rebalanceTriggerPath(
        uint8 _rangeSide,
        uint256 _ordinaryInventoryObserved,
        uint256 _sameSideObserved,
        uint256 _oscillationInventoryObserved
    ) internal pure returns (uint8 triggerPath_) {
        if (_rangeSide == RANGE_SIDE_IN_RANGE) return REBALANCE_PATH_NONE;
        if (_ordinaryInventoryObserved >= REBALANCE_CONSECUTIVE_TRIGGER) return REBALANCE_PATH_ORDINARY;
        if (_sameSideObserved < REBALANCE_OSCILLATION_SIDE_TRIGGER) return REBALANCE_PATH_NONE;
        if (_oscillationInventoryObserved < REBALANCE_CONSECUTIVE_TRIGGER) return REBALANCE_PATH_NONE;
        return REBALANCE_PATH_OSCILLATION;
    }

    /**
     * @notice Returns the latest inventory ratio measured for rebalance sampling.
     * @dev Prefers the live spot price and falls back to strategy valuation window if spot is unavailable.
     *      This ratio is about current strategy inventory, not the target ratio for a future rebalance.
     *      Inventory is reconstructed entirely inside the runner from:
     *      - the strategy's current idle ERC20 balances, and
     *      - the live Uniswap V3 position NFT referenced by `positionTokenId()`.
     * @return inventoryOtherRatioBPS_ Share of total inventory value held in `otherToken`.
     */
    function _currentInventoryOtherRatioBPS() internal view returns (uint16 inventoryOtherRatioBPS_) {
        uint160 _inventorySqrtPriceX96 = _currentInventorySqrtPriceX96();
        if (_inventorySqrtPriceX96 == 0) return 0;

        (uint256 _underlyingValue, uint256 _otherValueInUnderlying) =
            _strategyInventoryValuesAtSqrtPrice(_inventorySqrtPriceX96);
        uint256 _totalValue = _underlyingValue + _otherValueInUnderlying;
        if (_totalValue == 0) return 0;

        return uint16(Math.mulDiv(_otherValueInUnderlying, MAX_BPS, _totalValue));
    }

    /**
     * @notice Values the strategy's current inventory split at a supplied sqrt price.
     * @dev The runner reconstructs inventory from the public strategy getters and the Uniswap
     *      position manager directly so it does not depend on a strategy upgrade.
     *      The returned pair intentionally keeps underlying-side value and other-side value
     *      separate because rebalance heuristics care about how one-sided the inventory is.
     * @param _sqrtPriceX96 Valuation sqrt price in Q96.
     * @return underlyingValue_ Value already held in underlying units.
     * @return otherValueInUnderlying_ Value attributable to `otherToken`, quoted in underlying units.
     */
    function _strategyInventoryValuesAtSqrtPrice(uint160 _sqrtPriceX96)
        internal
        view
        returns (uint256 underlyingValue_, uint256 otherValueInUnderlying_)
    {
        uint256 _positionTokenId = ISFUniV3StrategyAutomationView(uniStrategy).positionTokenId();
        if (_positionTokenId != 0) {
            (underlyingValue_, otherValueInUnderlying_) =
                _positionInventoryValuesAtSqrtPrice(_positionTokenId, _sqrtPriceX96);
        }

        (underlyingValue_, otherValueInUnderlying_) = _accumulateInventoryLeg(
            underlyingValue_,
            otherValueInUnderlying_,
            underlyingToken,
            IERC20(underlyingToken).balanceOf(uniStrategy),
            _sqrtPriceX96
        );
        (underlyingValue_, otherValueInUnderlying_) = _accumulateInventoryLeg(
            underlyingValue_,
            otherValueInUnderlying_,
            otherToken,
            IERC20(otherToken).balanceOf(uniStrategy),
            _sqrtPriceX96
        );
    }

    /**
     * @notice Values the strategy's active Uniswap V3 position, including owed fees.
     * @dev The runner reads the position NFT directly from the NonfungiblePositionManager and
     *      values both the liquidity inventory and `tokensOwed{0,1}` at the supplied price.
     * @param _positionTokenId Active position NFT id.
     * @param _sqrtPriceX96 Valuation sqrt price in Q96.
     * @return underlyingValue_ Value attributable to underlying inventory.
     * @return otherValueInUnderlying_ Value attributable to other-token inventory, quoted in underlying units.
     */
    function _positionInventoryValuesAtSqrtPrice(uint256 _positionTokenId, uint160 _sqrtPriceX96)
        internal
        view
        returns (uint256 underlyingValue_, uint256 otherValueInUnderlying_)
    {
        address _token0 = PositionReader._getAddress(POSITION_MANAGER, _positionTokenId, 2);
        address _token1 = PositionReader._getAddress(POSITION_MANAGER, _positionTokenId, 3);
        int24 _tickLower = PositionReader._getInt24(POSITION_MANAGER, _positionTokenId, 5);
        int24 _tickUpper = PositionReader._getInt24(POSITION_MANAGER, _positionTokenId, 6);
        uint128 _liquidity = PositionReader._getUint128(POSITION_MANAGER, _positionTokenId, 7);

        if (_liquidity != 0) {
            (uint256 _amount0, uint256 _amount1) = LiquidityAmountsV3.getAmountsForLiquidity(
                _sqrtPriceX96,
                TickMathV3.getSqrtRatioAtTick(_tickLower),
                TickMathV3.getSqrtRatioAtTick(_tickUpper),
                _liquidity
            );

            (underlyingValue_, otherValueInUnderlying_) =
                _accumulateInventoryLeg(underlyingValue_, otherValueInUnderlying_, _token0, _amount0, _sqrtPriceX96);
            (underlyingValue_, otherValueInUnderlying_) =
                _accumulateInventoryLeg(underlyingValue_, otherValueInUnderlying_, _token1, _amount1, _sqrtPriceX96);
        }

        uint128 _owed0 = PositionReader._getUint128(POSITION_MANAGER, _positionTokenId, 10);
        uint128 _owed1 = PositionReader._getUint128(POSITION_MANAGER, _positionTokenId, 11);

        (underlyingValue_, otherValueInUnderlying_) =
            _accumulateInventoryLeg(underlyingValue_, otherValueInUnderlying_, _token0, uint256(_owed0), _sqrtPriceX96);
        (underlyingValue_, otherValueInUnderlying_) =
            _accumulateInventoryLeg(underlyingValue_, otherValueInUnderlying_, _token1, uint256(_owed1), _sqrtPriceX96);
    }

    /**
     * @notice Adds one inventory leg into the running underlying-vs-other valuation split.
     * @dev Unknown tokens are ignored because the strategy pair is expected to be exactly
     *      `(underlyingToken, otherToken)`. Ignoring anything else is safer than accidentally
     *      mis-valuing it as one side of the pair.
     * @param _underlyingValue Current accumulated underlying-side value.
     * @param _otherValueInUnderlying Current accumulated other-token-side value in underlying units.
     * @param _token Token represented by `_amount`.
     * @param _amount Token amount to account for.
     * @param _sqrtPriceX96 Valuation sqrt price in Q96.
     * @return newUnderlyingValue_ Updated underlying-side value.
     * @return newOtherValueInUnderlying_ Updated other-token-side value.
     */
    function _accumulateInventoryLeg(
        uint256 _underlyingValue,
        uint256 _otherValueInUnderlying,
        address _token,
        uint256 _amount,
        uint160 _sqrtPriceX96
    ) internal view returns (uint256 newUnderlyingValue_, uint256 newOtherValueInUnderlying_) {
        newUnderlyingValue_ = _underlyingValue;
        newOtherValueInUnderlying_ = _otherValueInUnderlying;
        if (_amount == 0) return (newUnderlyingValue_, newOtherValueInUnderlying_);

        if (_token == underlyingToken) {
            newUnderlyingValue_ += _amount;
        } else if (_token == otherToken) {
            newOtherValueInUnderlying_ += _quoteOtherAsUnderlyingAtSqrtPrice(_amount, _sqrtPriceX96);
        }
    }

    /**
     * @notice Returns the valuation price used for inventory-side sampling.
     * @return sqrtPriceX96_ Spot price when available, otherwise the strategy valuation fallback.
     */
    function _currentInventorySqrtPriceX96() internal view returns (uint160 sqrtPriceX96_) {
        (sqrtPriceX96_,,,,,,) = pool.slot0();
        if (sqrtPriceX96_ != 0) return sqrtPriceX96_;

        uint32 _window = ISFUniV3StrategyAutomationView(uniStrategy).twapWindow();
        return _valuationSqrtPriceX96(_window);
    }

    /**
     * @notice Evaluates the current peg guard using spot and strict 30-minute TWAP prices.
     * @dev This guard fails closed when either price is unavailable.
     *      The two checks intentionally answer different questions:
     *      - `spot vs peg` asks whether the pool itself is trading off the intended 1:1 anchor
     *      - `spot vs TWAP` asks whether the current spot move is materially detached from recent consensus
     * @return status_ Current peg-guard result and diagnostics.
     */
    function _evaluatePegGuard() internal view returns (PegGuardStatus memory status_) {
        (uint160 _spotSqrtPriceX96,,,,,,) = pool.slot0();
        if (_spotSqrtPriceX96 == 0) return status_;

        (bool _twapOk, uint160 _twapSqrtPriceX96) = _strictTwapSqrtPriceX96(REBALANCE_PEG_GUARD_TWAP_WINDOW);
        if (!_twapOk || _twapSqrtPriceX96 == 0) return status_;

        uint256 _spotPriceE18 = _normalizedOtherPriceE18(_spotSqrtPriceX96);
        uint256 _twapPriceE18 = _normalizedOtherPriceE18(_twapSqrtPriceX96);
        status_.spotPegDeviationBPS = _deviationBPS(_spotPriceE18, 1e18);
        status_.spotVsTwapDeviationBPS = _deviationBPS(_spotPriceE18, _twapPriceE18);
        status_.passed = status_.spotPegDeviationBPS <= REBALANCE_PEG_GUARD_BPS
            && status_.spotVsTwapDeviationBPS <= REBALANCE_PEG_GUARD_BPS;
    }

    /**
     * @notice Computes a strict TWAP price without falling back to spot.
     * @dev Used only by peg guard. This helper must not silently degrade to spot because peg guard
     *      is intended to fail closed when a proper TWAP cannot be obtained.
     * @param _window TWAP window in seconds.
     * @return ok_ True when a TWAP price was produced successfully.
     * @return sqrtPriceX96_ TWAP sqrt price in Q96.
     */
    function _strictTwapSqrtPriceX96(uint32 _window) internal view returns (bool ok_, uint160 sqrtPriceX96_) {
        if (_window == 0) return (false, 0);

        uint32[] memory _secondsAgos = new uint32[](2);
        _secondsAgos[0] = _window;
        _secondsAgos[1] = 0;

        try pool.observe(_secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 _delta = tickCumulatives[1] - tickCumulatives[0];
            int56 _secs = int56(uint56(_window));

            int24 _avgTick = int24(_delta / _secs);
            if (_delta < 0 && (_delta % _secs != 0)) _avgTick--;

            return (true, TickMathV3.getSqrtRatioAtTick(_avgTick));
        } catch {
            return (false, 0);
        }
    }

    /**
     * @notice Converts a sqrt price into normalized underlying-per-other price scaled to 1e18.
     * @dev Normalization makes both pool token orderings comparable against the same 1.0 peg.
     * @param _sqrtPriceX96 Sqrt price Q64.96.
     * @return priceE18_ Normalized price used by peg guard.
     */
    function _normalizedOtherPriceE18(uint160 _sqrtPriceX96) internal view returns (uint256 priceE18_) {
        uint256 _priceX192 = uint256(_sqrtPriceX96) * uint256(_sqrtPriceX96);
        uint256 _q192 = 1 << 192;

        if (otherIsToken0) {
            return Math.mulDiv(1e18, _priceX192, _q192);
        }

        return Math.mulDiv(1e18, _q192, _priceX192);
    }

    /**
     * @notice Computes absolute deviation in BPS between two normalized prices.
     * @dev Returns `type(uint16).max` if either side is zero so peg guard can fail closed
     *      without introducing special cases at the call site.
     * @param _lhs Left-hand price.
     * @param _rhs Right-hand price.
     * @return deviationBPS_ Absolute deviation expressed in BPS of `_rhs`.
     */
    function _deviationBPS(uint256 _lhs, uint256 _rhs) internal pure returns (uint16 deviationBPS_) {
        if (_lhs == 0 || _rhs == 0) return type(uint16).max;
        uint256 _diff = _lhs > _rhs ? _lhs - _rhs : _rhs - _lhs;
        uint256 _bps = Math.mulDiv(_diff, MAX_BPS, _rhs);
        if (_bps > type(uint16).max) return type(uint16).max;
        return uint16(_bps);
    }

    /**
     * @notice Returns whether an inventory ratio satisfies a one-sided threshold.
     * @dev Example:
     *      - threshold 500 -> valid for `<= 5%` or `>= 95%`
     *      - threshold 2000 -> valid for `<= 20%` or `>= 80%`
     * @param _ratioBPS Inventory other-token ratio in BPS.
     * @param _thresholdBPS Maximum allowed minority share in BPS.
     * @return True when inventory is one-sided enough on either side.
     */
    function _isInventoryOneSided(uint16 _ratioBPS, uint16 _thresholdBPS) internal pure returns (bool) {
        return _ratioBPS <= _thresholdBPS || _ratioBPS >= uint16(MAX_BPS - _thresholdBPS);
    }

    /**
     * @notice Encodes which side of the current strategy band the monitoring tick is on.
     * @param _currentTick Monitoring tick used by the runner.
     * @param _tickLower Current lower tick.
     * @param _tickUpper Current upper tick.
     * @return rangeSide_ Encoded range side.
     */
    function _rangeSideForTick(int24 _currentTick, int24 _tickLower, int24 _tickUpper)
        internal
        pure
        returns (uint8 rangeSide_)
    {
        if (_currentTick < _tickLower) return RANGE_SIDE_BELOW;
        if (_currentTick >= _tickUpper) return RANGE_SIDE_ABOVE;
        return RANGE_SIDE_IN_RANGE;
    }

    /**
     * @notice Returns whether the invest cadence has elapsed.
     * @return True when invest execution is allowed by the current schedule.
     */
    function _isInvestWindowOpen() internal view returns (bool) {
        return block.timestamp >= lastRun + interval;
    }

    /**
     * @notice Rounds a tick down to the nearest valid multiple of pool spacing.
     * @param _tick Tick to round.
     * @param _spacing Pool tick spacing.
     * @return Rounded tick that does not exceed `_tick`.
     */
    function _floorToSpacing(int24 _tick, int24 _spacing) internal pure returns (int24) {
        int24 q = _tick / _spacing;
        int24 r = _tick % _spacing;
        if (_tick < 0 && r != 0) q -= 1;
        return SafeCast.toInt24(int256(q) * int256(_spacing));
    }

    /**
     * @notice Rounds a tick up to the nearest valid multiple of pool spacing.
     * @param _tick Tick to round.
     * @param _spacing Pool tick spacing.
     * @return Rounded tick that is not below `_tick`.
     */
    function _ceilToSpacing(int24 _tick, int24 _spacing) internal pure returns (int24) {
        int24 q = _tick / _spacing;
        int24 r = _tick % _spacing;
        if (_tick > 0 && r != 0) q += 1;
        return SafeCast.toInt24(int256(q) * int256(_spacing));
    }

    /**
     * @notice Computes target other-token ratio for the current range/price.
     * @dev Uses unit-liquidity equivalent in-range composition.
     * @param _sqrtPriceX96 Current sqrt price in Q96.
     * @param _tickLower Lower bound of the target range.
     * @param _tickUpper Upper bound of the target range.
     * @return Ratio of other-token value in BPS.
     */
    function _computeOtherRatioBPS(uint160 _sqrtPriceX96, int24 _tickLower, int24 _tickUpper)
        internal
        view
        returns (uint16)
    {
        uint160 _sa = TickMathV3.getSqrtRatioAtTick(_tickLower);
        uint160 _sb = TickMathV3.getSqrtRatioAtTick(_tickUpper);
        if (_sa > _sb) (_sa, _sb) = (_sb, _sa);

        // Outside the band the optimal composition is fully concentrated in one token.
        if (_sqrtPriceX96 <= _sa) return otherIsToken0 ? uint16(MAX_BPS) : uint16(0);
        if (_sqrtPriceX96 >= _sb) return otherIsToken0 ? uint16(0) : uint16(MAX_BPS);

        // In-range token mix (unit-liquidity equivalent), valued in token1 units:
        // token0ValueInToken1 = ((sb - p) * p) / sb
        // token1ValueInToken1 = (p - sa)
        uint256 _token0ValueInToken1 = Math.mulDiv(uint256(_sb - _sqrtPriceX96), uint256(_sqrtPriceX96), uint256(_sb));
        uint256 _token1ValueInToken1 = uint256(_sqrtPriceX96 - _sa);
        uint256 _totalValueInToken1 = _token0ValueInToken1 + _token1ValueInToken1;
        if (_totalValueInToken1 == 0) return 0;

        uint256 _otherValueInToken1 = otherIsToken0 ? _token0ValueInToken1 : _token1ValueInToken1;
        return uint16(Math.mulDiv(_otherValueInToken1, MAX_BPS, _totalValueInToken1));
    }

    /**
     * @notice Returns valuation sqrt price using TWAP when configured, otherwise spot.
     * @dev Falls back to spot `slot0` when observe call fails.
     * @param _window TWAP window in seconds (0 means spot).
     * @return sqrtPriceX96_ Valuation sqrt price in Q96.
     */
    function _valuationSqrtPriceX96(uint32 _window) internal view returns (uint160 sqrtPriceX96_) {
        if (_window == 0) {
            (sqrtPriceX96_,,,,,,) = pool.slot0();
            return sqrtPriceX96_;
        }

        // Query the cumulative ticks over the requested window and derive the mean tick.
        uint32[] memory _secondsAgos = new uint32[](2);
        _secondsAgos[0] = _window;
        _secondsAgos[1] = 0;

        try pool.observe(_secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 _delta = tickCumulatives[1] - tickCumulatives[0];
            int56 _secs = int56(uint56(_window));

            int24 _avgTick = int24(_delta / _secs);
            if (_delta < 0 && (_delta % _secs != 0)) _avgTick--;

            return TickMathV3.getSqrtRatioAtTick(_avgTick);
        } catch {
            // If observe is unavailable, fall back to the live spot price instead of reverting.
            (sqrtPriceX96_,,,,,,) = pool.slot0();
            return sqrtPriceX96_;
        }
    }

    /**
     * @notice Quotes `otherToken` amount into underlying units at a given sqrt price.
     * @dev Reverts if pool token ordering is inconsistent with configured tokens.
     * @param _amountOther Amount of other token to value.
     * @param _sqrtPriceX96 Valuation sqrt price in Q96.
     * @return quotedUnderlying Equivalent value in underlying units.
     */
    function _quoteOtherAsUnderlyingAtSqrtPrice(uint256 _amountOther, uint160 _sqrtPriceX96)
        internal
        view
        returns (uint256)
    {
        if (_amountOther == 0) return 0;

        // Pool ordering was already validated during initialization, so `otherIsToken0`
        // is enough to choose the conversion direction.
        uint256 _priceX192 = uint256(_sqrtPriceX96) * uint256(_sqrtPriceX96);
        uint256 _q192 = 1 << 192;
        if (otherIsToken0) return Math.mulDiv(_amountOther, _priceX192, _q192);
        return Math.mulDiv(_amountOther, _q192, _priceX192);
    }

    /**
     * @notice Reads paused status from an arbitrary target via staticcall.
     * @dev Returns false when call fails or response is malformed.
     * @param _target Contract to probe for `paused()`.
     * @return paused_ True if target reports paused.
     */
    function _isPaused(address _target) internal view returns (bool paused_) {
        (bool _ok, bytes memory _data) = _target.staticcall(abi.encodeWithSignature("paused()"));
        if (!_ok || _data.length < 32) return false;
        paused_ = abi.decode(_data, (bool));
    }

    /**
     * @notice Checks whether Uni strategy is the only active weighted allocation in aggregator.
     * @dev Returns false on call failure.
     * @return True when at least one active weighted strategy exists and all such entries are `uniStrategy`.
     */
    function _isUniOnlyAllocation() internal view returns (bool) {
        try ISFAggregatorAutomationView(aggregator).getSubStrategies() returns (
            ISFAggregatorAutomationView.SubStrategyInfo[] memory subStrategies
        ) {
            bool _foundUni;
            uint256 _len = subStrategies.length;

            // Ignore inactive or zero-weight strategies; only the effective allocation matters.
            for (uint256 i; i < _len; ++i) {
                ISFAggregatorAutomationView.SubStrategyInfo memory _s = subStrategies[i];
                if (!_s.isActive || _s.targetWeightBPS == 0) continue;
                if (_s.strategy != uniStrategy) return false;
                _foundUni = true;
            }

            return _foundUni;
        } catch {
            return false;
        }
    }

    /**
     * @notice Seeds rebalance-specific runtime state for the upgrade.
     * @dev The state is initialized so the first upkeep after an upgrade can immediately
     *      rebalance if the live position already qualifies under the new rules:
     *      - the rebalance check window is already open
     *      - one synthetic sample is seeded 24 hours in the past using the live side and inventory ratio
     *      - the historical Arbitrum One last successful rebalance timestamp is preserved for bookkeeping
     *      The fixed-size sample arrays are explicitly zeroed first so reused proxies do not
     *      inherit stale buffered history.
     * @dev The seeded sample mirrors the live snapshot at initialization time so first-upkeep depends on real conditions.
     */
    function _initializeRebalanceState() internal {
        RebalanceObservation memory _observation = _currentRebalanceObservation();

        rebalanceCheckInterval = DAILY_INTERVAL;
        lastRebalanceCheck = block.timestamp - DAILY_INTERVAL;
        lastSuccessfulRebalance = 1_774_106_444; // March 21 rebalance.
        rebalanceEnabled = true;
        rebalanceSampleCount = 1;
        rebalanceSampleHead = 1;

        // Reset the entire ring buffer so a newly upgraded proxy starts sampling from scratch.
        for (uint256 i; i < REBALANCE_SAMPLE_CAP; ++i) {
            rebalanceSampleTimestamps[i] = 0;
            rebalanceSampleOutOfRange[i] = false;
            rebalanceSampleRangeSides[i] = RANGE_SIDE_IN_RANGE;
            rebalanceSampleInventoryOtherRatioBPS[i] = 0;
        }

        rebalanceSampleTimestamps[0] = uint40(block.timestamp - REBALANCE_CONSECUTIVE_TRIGGER);
        rebalanceSampleOutOfRange[0] = _observation.rangeSide != RANGE_SIDE_IN_RANGE;
        rebalanceSampleRangeSides[0] = _observation.rangeSide;
        rebalanceSampleInventoryOtherRatioBPS[0] = _observation.inventoryOtherRatioBPS;
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}
}
