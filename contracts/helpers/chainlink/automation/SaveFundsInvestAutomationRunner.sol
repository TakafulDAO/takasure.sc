// SPDX-License-Identifier: GPL-3.0

/**
 * @notice Chainlink-compatible upkeep runner that invests all idle SFVault assets
 *         through SFStrategyAggregator using a UniV3-targeted payload.
 * @dev Rules for investment attempts:
 *      - full vault idle assets (`SFVault.idleAssets()`)
 *      - auto `otherRatioBPS` from current price + [tickLower, tickUpper]
 *      - Universal Router swap payloads with amountIn BPS sentinel
 * @dev Rules for rebalance attempts:
 *     - Observe the strategy's monitoring tick against its current range on a configurable cadence.
 *     - Trigger a rebalance when the position has been continuously out of range for at least 24 hours, or when
 *       there is at least 24 hours of out-of-range history observed within a rolling 3-day window and the latest
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

import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ISFStrategyMaintenance} from "contracts/interfaces/saveFunds/ISFStrategyMaintenance.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
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
    uint256 internal constant REBALANCE_CONSECUTIVE_TRIGGER = 24 hours;
    uint256 internal constant REBALANCE_ROLLING_TRIGGER = 24 hours;
    uint256 internal constant REBALANCE_WINDOW = 3 days;
    uint256 internal constant REBALANCE_COOLDOWN = 7 days;
    uint8 internal constant REBALANCE_SAMPLE_CAP = 16;
    int24 internal constant REBALANCE_TICK_LOWER_OFFSET = -2;
    int24 internal constant REBALANCE_TICK_UPPER_OFFSET = 3;

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
    uint256 public lastSuccessfulRebalance;
    bool public rebalanceEnabled;
    uint8 internal rebalanceSampleCount;
    uint8 internal rebalanceSampleHead;
    uint40[REBALANCE_SAMPLE_CAP] internal rebalanceSampleTimestamps;
    bool[REBALANCE_SAMPLE_CAP] internal rebalanceSampleOutOfRange;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnUpkeepSkippedPaused(uint256 ts);
    event OnUpkeepSkippedLowIdle(uint256 ts, uint256 idleAssets, uint256 minIdleAssets);
    event OnUpkeepSkippedAllocation(uint256 ts);
    event OnUpkeepAttempt(uint256 ts, uint256 idleAssets, uint16 otherRatioBPS, bytes32 bundleHash);
    event OnInvestSucceeded(uint256 ts, uint256 requestedAssets, uint256 investedAssets, uint16 otherRatioBPS);
    event OnInvestFailed(uint256 ts, bytes reason);
    event OnRebalanceObserved(
        uint256 ts,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper,
        bool outOfRange,
        uint256 consecutiveObserved,
        uint256 rollingObserved,
        bool rebalanceNeeded
    );
    event OnRebalanceAttempt(
        uint256 ts, int24 currentTick, int24 newTickLower, int24 newTickUpper, uint16 otherRatioBPS, bytes32 bundleHash
    );
    event OnRebalanceSucceeded(
        uint256 ts, int24 currentTick, int24 newTickLower, int24 newTickUpper, uint16 otherRatioBPS
    );
    event OnRebalanceFailed(
        uint256 ts, int24 currentTick, int24 newTickLower, int24 newTickUpper, uint16 otherRatioBPS, bytes reason
    );
    event OnConfigUpdated();

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
        emit OnConfigUpdated();
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
        emit OnConfigUpdated();
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
        emit OnConfigUpdated();
    }

    /**
     * @notice Toggles test mode.
     * @dev Test mode allows shorter configured intervals for local and fork testing.
     */
    function toggleTestMode() external onlyOwner {
        testMode = !testMode;
        emit OnConfigUpdated();
    }

    /**
     * @notice Sets the minimum idle-assets threshold required to trigger investment.
     * @param newMinIdleAssets Minimum idle asset threshold in underlying units.
     */
    function setMinIdleAssets(uint256 newMinIdleAssets) external onlyOwner {
        minIdleAssets = newMinIdleAssets;
        emit OnConfigUpdated();
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
        emit OnConfigUpdated();
    }

    /**
     * @notice Toggles strict allocation mode that requires Uni strategy to be the only active allocation.
     * @dev This protects the existing single-strategy bundle builder from being used when the
     *      aggregator is configured to route capital elsewhere.
     */
    function toggleStrictUniOnlyAllocation() external onlyOwner whenNotPaused {
        strictUniOnlyAllocation = !strictUniOnlyAllocation;
        emit OnConfigUpdated();
    }

    /**
     * @notice Toggles the rebalance branch of the upkeep.
     * @dev Invest automation remains available even when rebalance automation is disabled.
     */
    function toggleRebalanceEnabled() external onlyOwner whenNotPaused {
        rebalanceEnabled = !rebalanceEnabled;
        emit OnConfigUpdated();
    }

    /**
     * @notice Toggles automatic ratio computation for invest payloads.
     * @dev When disabled, `manualOtherRatioBPS` is used for both preview and invest execution.
     */
    function setUseAutoOtherRatio() external onlyOwner whenNotPaused {
        useAutoOtherRatio = !useAutoOtherRatio;
        emit OnConfigUpdated();
    }

    /**
     * @notice Sets manual `otherRatioBPS` used when auto ratio is disabled.
     * @param bps Target ratio for other token in BPS (0..10000).
     */
    function setManualOtherRatioBPS(uint16 bps) external onlyOwner whenNotPaused {
        require(bps <= MAX_BPS, SaveFundsInvestAutomationRunner__OutOfRange());
        manualOtherRatioBPS = bps;
        emit OnConfigUpdated();
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
        emit OnConfigUpdated();
    }

    /**
     * @notice Sets minimum amounts for position manager actions.
     * @param minUnderlying_ Minimum underlying amount for PM operations.
     * @param minOther_ Minimum other-token amount for PM operations.
     */
    function setPositionMins(uint256 minUnderlying_, uint256 minOther_) external onlyOwner whenNotPaused {
        minUnderlying = minUnderlying_;
        minOther = minOther_;
        emit OnConfigUpdated();
    }

    /**
     * @notice Sets a deadline buffer for position manager actions.
     * @param deadlineBuffer_ Buffer in seconds added to `block.timestamp` for PM deadlines.
     */
    function setDeadlineBuffer(uint256 deadlineBuffer_) external onlyOwner whenNotPaused {
        deadlineBuffer = deadlineBuffer_;
        emit OnConfigUpdated();
    }

    /**
     * @notice Manually sets `lastRun`.
     * @dev Useful for operational recovery and scheduling adjustments.
     * @param ts New timestamp to store as `lastRun`.
     */
    function setLastRun(uint256 ts) external onlyOwner {
        lastRun = ts;
        emit OnConfigUpdated();
    }

    /**
     * @notice Seeds the timestamp used by the 7-day rebalance cooldown rule.
     * @dev Useful when migrating an already-operated strategy into the upgraded runner.
     * @param ts Timestamp to store as the latest successful rebalance time.
     */
    function setLastSuccessfulRebalance(uint256 ts) external onlyOwner {
        lastSuccessfulRebalance = ts;
        emit OnConfigUpdated();
    }

    /*//////////////////////////////////////////////////////////////
                            KEEPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Chainlink Automation fallback function.
     * @dev This function is intentionally conservative: it only reports upkeep when either
     *      an invest attempt or a rebalance observation is currently actionable.
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
     */
    function performUpkeep(bytes calldata) external {
        if (paused()) return;

        bool investWindowOpen = _isInvestWindowOpen();
        bool rebalanceCheckNeeded = _shouldCheckRebalance();
        if (!investWindowOpen && !rebalanceCheckNeeded) return;

        if (skipIfPaused) {
            if (_isPaused(address(vault)) || _isPaused(aggregator) || _isPaused(uniStrategy)) {
                // Advance the relevant clocks to avoid spamming repeated attempts while the
                // downstream protocol components are intentionally paused.
                if (rebalanceCheckNeeded) lastRebalanceCheck = block.timestamp;
                if (investWindowOpen) lastRun = block.timestamp;
                emit OnUpkeepSkippedPaused(block.timestamp);
                return;
            }
        }

        // Rebalance failure short-circuits the upkeep so the runner does not add new capital
        // into a position it just failed to move.
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

        // Preserve the existing invest scheduling semantics: `lastRun` advances exactly on
        // the path where the runner commits to an invest attempt.
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
            // Spot should be the normal path. TWAP only exists as a defensive fallback when
            // slot0 returns an unusable zero price.
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
     * @notice Records the latest range observation and executes rebalance when rules are met.
     * @dev Returns `true` only when a rebalance attempt was made and failed. The caller uses
     *      that signal to skip the invest branch for the same upkeep.
     * @return rebalanceFailed_ True when a rebalance attempt reverted.
     */
    function _observeAndMaybeRebalance() internal returns (bool rebalanceFailed_) {
        lastRebalanceCheck = block.timestamp;

        // Sample the current range state first so both the event and the trigger logic use
        // exactly the same observation.
        (bool _outOfRange, int24 _currentTick, int24 _tickLower, int24 _tickUpper) = _currentRangeStatus();
        _recordRebalanceSample(_outOfRange);

        uint256 _consecutiveObserved = _consecutiveOutOfRangeObserved();
        uint256 _rollingObserved = _rollingOutOfRangeObserved(block.timestamp - REBALANCE_WINDOW);
        bool _rebalanceNeeded = _outOfRange && _shouldTriggerRebalance(_consecutiveObserved, _rollingObserved);

        emit OnRebalanceObserved(
            block.timestamp,
            _currentTick,
            _tickLower,
            _tickUpper,
            _outOfRange,
            _consecutiveObserved,
            _rollingObserved,
            _rebalanceNeeded
        );

        if (!_rebalanceNeeded) return false;

        // Compute the next band from the live monitoring tick, then reuse the invest ratio
        // math so the rebalance mints into the new band with the same capital-efficiency logic.
        (int24 _newTickLower, int24 _newTickUpper) = _computeRebalanceTicks(_currentTick);
        uint16 _otherRatioBPS = _resolveAutoOtherRatioBPSForRange(0, _newTickLower, _newTickUpper);
        bytes memory _rebalancePayload = abi.encode(_newTickLower, _newTickUpper, _buildUniV3Payload(_otherRatioBPS));
        (,, bytes memory _bundle) = _buildSingleStrategyBundle(_rebalancePayload);

        emit OnRebalanceAttempt(
            block.timestamp, _currentTick, _newTickLower, _newTickUpper, _otherRatioBPS, keccak256(_bundle)
        );

        try ISFStrategyMaintenance(aggregator).rebalance(_bundle) {
            lastSuccessfulRebalance = block.timestamp;
            _clearRebalanceSamples();
            emit OnRebalanceSucceeded(block.timestamp, _currentTick, _newTickLower, _newTickUpper, _otherRatioBPS);
        } catch (bytes memory reason) {
            rebalanceFailed_ = true;
            emit OnRebalanceFailed(block.timestamp, _currentTick, _newTickLower, _newTickUpper, _otherRatioBPS, reason);
        }
    }

    /**
     * @notice Determines whether a new rebalance observation should be sampled now.
     * @dev The runner keeps sampling while the position is currently out of range or when there
     *      is recent out-of-range history inside the rolling window.
     * @return True when the rebalance observer should run.
     */
    function _shouldCheckRebalance() internal view returns (bool) {
        if (!rebalanceEnabled) return false;
        if (block.timestamp < lastRebalanceCheck + rebalanceCheckInterval) return false;

        // Continue sampling after the position comes back in range so the rolling-window rule
        // can still be evaluated from recent history.
        (bool _outOfRange,,,) = _currentRangeStatus();
        if (_outOfRange) return true;

        return _hasRecentOutOfRangeSample(block.timestamp - REBALANCE_WINDOW);
    }

    /**
     * @notice Evaluates the rebalance trigger rules from sampled out-of-range history.
     * @param _consecutiveObserved Most recent consecutive out-of-range observed duration.
     * @param _rollingObserved Total out-of-range observed duration inside the rolling window.
     * @return True when either the consecutive or rolling-window rule is satisfied.
     */
    function _shouldTriggerRebalance(uint256 _consecutiveObserved, uint256 _rollingObserved)
        internal
        view
        returns (bool)
    {
        if (_consecutiveObserved >= REBALANCE_CONSECUTIVE_TRIGGER) return true;
        if (_rollingObserved < REBALANCE_ROLLING_TRIGGER) return false;
        if (lastSuccessfulRebalance == 0) return true;
        return block.timestamp >= lastSuccessfulRebalance + REBALANCE_COOLDOWN;
    }

    /**
     * @notice Returns the current range state for the UniV3 strategy.
     * @dev Uses the monitoring tick source rather than the raw spot tick directly so the same
     *      fallback logic is shared everywhere the runner reasons about range status.
     * @return outOfRange_ True when the current monitoring tick is outside the strategy band.
     * @return currentTick_ Tick used for the range check.
     * @return tickLower_ Current strategy lower tick.
     * @return tickUpper_ Current strategy upper tick.
     */
    function _currentRangeStatus()
        internal
        view
        returns (bool outOfRange_, int24 currentTick_, int24 tickLower_, int24 tickUpper_)
    {
        (tickLower_, tickUpper_) = _currentStrategyTicks();
        currentTick_ = _currentMonitoringTick();
        outOfRange_ = currentTick_ < tickLower_ || currentTick_ >= tickUpper_;
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
        if (_fallbackSqrtPriceX96 != 0) {
            tick_ = TickMathV3.getTickAtSqrtRatio(_fallbackSqrtPriceX96);
        }
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
     * @notice Stores one rebalance observation in the fixed-size ring buffer.
     * @dev New samples overwrite the oldest entries once the buffer reaches capacity.
     * @param _outOfRange Whether the observed strategy state was out of range.
     */
    function _recordRebalanceSample(bool _outOfRange) internal {
        rebalanceSampleTimestamps[rebalanceSampleHead] = uint40(block.timestamp);
        rebalanceSampleOutOfRange[rebalanceSampleHead] = _outOfRange;

        rebalanceSampleHead = uint8((uint256(rebalanceSampleHead) + 1) % REBALANCE_SAMPLE_CAP);
        if (rebalanceSampleCount < REBALANCE_SAMPLE_CAP) ++rebalanceSampleCount;
    }

    /**
     * @notice Clears the active rebalance sample window after a successful rebalance.
     * @dev The old array contents are intentionally left in storage; only the active ring-buffer
     *      head and count are reset.
     */
    function _clearRebalanceSamples() internal {
        rebalanceSampleCount = 0;
        rebalanceSampleHead = 0;
    }

    /**
     * @notice Computes the latest consecutive out-of-range observed duration.
     * @dev The duration is based on sampled observations, not continuous oracle history.
     * @return duration_ Observed consecutive out-of-range time in seconds.
     */
    function _consecutiveOutOfRangeObserved() internal view returns (uint256 duration_) {
        if (rebalanceSampleCount == 0) return 0;

        uint256 _latestIndex = _sampleIndexFromNewest(0);
        if (!rebalanceSampleOutOfRange[_latestIndex]) return 0;

        uint256 _latestTs = uint256(rebalanceSampleTimestamps[_latestIndex]);
        uint256 _earliestTs = _latestTs;

        // Walk backward until the first in-range sample to measure the most recent contiguous
        // out-of-range streak.
        for (uint256 offset = 1; offset < rebalanceSampleCount; ++offset) {
            uint256 _idx = _sampleIndexFromNewest(offset);
            if (!rebalanceSampleOutOfRange[_idx]) break;
            _earliestTs = uint256(rebalanceSampleTimestamps[_idx]);
        }

        return _latestTs - _earliestTs;
    }

    /**
     * @notice Computes sampled out-of-range time inside a rolling window.
     * @dev Only intervals bounded by two consecutive out-of-range samples are counted, which
     *      makes the result conservative relative to continuous observation.
     * @param _windowStart Start timestamp of the rolling window.
     * @return duration_ Observed out-of-range duration inside the window.
     */
    function _rollingOutOfRangeObserved(uint256 _windowStart) internal view returns (uint256 duration_) {
        if (rebalanceSampleCount < 2) return 0;

        uint256 _previousTs;
        bool _previousOut;

        // Traverse oldest-to-newest so each pair of adjacent samples contributes at most once.
        for (uint256 i; i < rebalanceSampleCount; ++i) {
            uint256 _idx = _sampleIndexFromOldest(i);
            uint256 _ts = uint256(rebalanceSampleTimestamps[_idx]);
            bool _out = rebalanceSampleOutOfRange[_idx];

            // Count only the overlap of an out-of-range interval with the requested window.
            if (i != 0 && _previousOut && _out && _ts > _windowStart) {
                uint256 _intervalStart = _previousTs > _windowStart ? _previousTs : _windowStart;
                if (_ts > _intervalStart) duration_ += _ts - _intervalStart;
            }

            _previousTs = _ts;
            _previousOut = _out;
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
        if (underlyingToken == otherToken) return _amountOther;

        // Convert using the pool price and the known token ordering of the strategy pair.
        uint256 _priceX192 = uint256(_sqrtPriceX96) * uint256(_sqrtPriceX96);
        uint256 _q192 = 1 << 192;

        address _token0 = pool.token0();
        address _token1 = pool.token1();

        if (otherToken == _token0 && underlyingToken == _token1) {
            return Math.mulDiv(_amountOther, _priceX192, _q192);
        }
        require(otherToken == _token1 && underlyingToken == _token0, SaveFundsInvestAutomationRunner__BadPoolConfig());
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
     * @notice Resets rebalance-specific runtime state to the default values for this version.
     * @dev The fixed-size sample arrays are explicitly zeroed so future upgrades do not inherit
     *      stale values when this initializer is invoked on a reused proxy.
     */
    function _initializeRebalanceState() internal {
        rebalanceCheckInterval = DAILY_INTERVAL;
        lastRebalanceCheck = 0;
        lastSuccessfulRebalance = 0;
        rebalanceEnabled = true;
        rebalanceSampleCount = 0;
        rebalanceSampleHead = 0;

        // Reset the entire ring buffer so a newly upgraded proxy starts sampling from scratch.
        for (uint256 i; i < REBALANCE_SAMPLE_CAP; ++i) {
            rebalanceSampleTimestamps[i] = 0;
            rebalanceSampleOutOfRange[i] = false;
        }
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        newImplementation;
    }
}
