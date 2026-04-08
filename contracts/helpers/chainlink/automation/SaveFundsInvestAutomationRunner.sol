// SPDX-License-Identifier: GPL-3.0

/**
 * @notice Chainlink-compatible upkeep runner that invests all idle SFVault assets
 *         through SFStrategyAggregator using a UniV3-targeted payload.
 * @dev This mirrors buildVaultInvestCalldata.js behavior on-chain:
 *      - full vault idle assets (`SFVault.idleAssets()`)
 *      - auto `otherRatioBPS` from current price + [tickLower, tickUpper]
 *      - Universal Router swap payloads with amountIn BPS sentinel
 *
 *      Important: the aggregator still allocates by configured target weights.
 *      This runner has `strictUniOnlyAllocation` enabled by default to avoid
 *      accidental routing into non-Uni strategies.
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

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
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
    uint8 internal constant ROUTE_V3_SINGLE_HOP = 1;
    uint8 internal constant ROUTE_V4_SINGLE_HOP = 2;

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

    event OnUpkeepSkippedPaused(uint256 ts);
    event OnUpkeepSkippedLowIdle(uint256 ts, uint256 idleAssets, uint256 minIdleAssets);
    event OnUpkeepSkippedAllocation(uint256 ts);
    event OnUpkeepAttempt(uint256 ts, uint256 idleAssets, uint16 otherRatioBPS, bytes32 bundleHash);
    event OnInvestSucceeded(uint256 ts, uint256 requestedAssets, uint256 investedAssets, uint16 otherRatioBPS);
    event OnInvestFailed(uint256 ts, bytes reason);
    event OnConfigUpdated();

    error SaveFundsInvestAutomationRunner__NotAddressZero();
    error SaveFundsInvestAutomationRunner__TooSmall();
    error SaveFundsInvestAutomationRunner__OutOfRange();
    error SaveFundsInvestAutomationRunner__BadPoolConfig();
    error SaveFundsInvestAutomationRunner__BadStrategyConfig();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the runner.
     * @param _vault SFVault address.
     * @param _aggregator SFStrategyAggregator address.
     * @param _uniStrategy SFUniswapV3Strategy address.
     * @param _addressManager AddressManager address.
     * @param _intervalSeconds Upkeep interval in seconds (0 for default 24h).
     * @param _minIdleAssets Minimum idle assets required to attempt investment.
     * @param _owner Initial owner for access control.
     */
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

    /**
     * @notice Accepts the proposed `KEEPER` role in AddressManager.
     * @dev Callable by anyone; success depends on AddressManager proposal state.
     */
    function acceptKeeperRole() external {
        addressManager.acceptProposedRole(Roles.KEEPER);
    }

    /**
     * @notice Sets the execution interval for upkeep runs.
     * @dev Restricted to owner. Minimum allowed value is 24 hours unless `testMode` is enabled.
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

    /// @notice Toggles test mode.
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

    /**
     * @notice Pauses upkeep execution for this runner.
     * @dev Restricted to owner.
     */
    function pause() external onlyOwner whenNotPaused {
        _pause();
    }

    /**
     * @notice Unpauses upkeep execution for this runner.
     * @dev Restricted to owner.
     */
    function unpause() external onlyOwner whenPaused {
        _unpause();
    }

    /// @notice Toggles dependency paused-state checks during upkeep.
    function toggleSkipIfPaused() external onlyOwner whenNotPaused {
        skipIfPaused = !skipIfPaused;
        emit OnConfigUpdated();
    }

    /// @notice Toggles strict allocation mode that requires Uni strategy to be the only active allocation.
    function toggleStrictUniOnlyAllocation() external onlyOwner whenNotPaused {
        strictUniOnlyAllocation = !strictUniOnlyAllocation;
        emit OnConfigUpdated();
    }

    /// @notice Toggles automatic ratio computation for invest payloads.
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
     * @notice Chainlink Automation fallback function.
     * @dev It does not revert if paused.
     * @dev Returns false when paused, interval not elapsed, dependencies are paused,
     *      strict allocation check fails, or idle assets are below threshold.
     * @return upkeepNeeded True when upkeep should be executed.
     * @return performData ABI-encoded payload for `performUpkeep` (currently idle assets).
     */
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        if (paused()) return (false, bytes(""));
        if (block.timestamp < lastRun + interval) return (false, bytes(""));

        if (skipIfPaused) {
            if (_isPaused(address(vault)) || _isPaused(aggregator) || _isPaused(uniStrategy)) {
                return (false, bytes(""));
            }
        }

        if (strictUniOnlyAllocation && !_isUniOnlyAllocation()) return (false, bytes(""));

        uint256 idle;
        try vault.idleAssets() returns (uint256 assets) {
            idle = assets;
        } catch {
            return (false, bytes(""));
        }

        if (idle == 0 || idle < minIdleAssets) return (false, bytes(""));

        performData = abi.encode(idle);
        return (true, performData);
    }

    /**
     * @notice Chainlink Automation perform function.
     * @dev Reads full idle assets from vault, builds UniV3 invest payload, and calls vault invest.
     *      Emits success/failure events and updates `lastRun` on execution path.
     */
    function performUpkeep(bytes calldata) external {
        if (paused()) return;
        if (block.timestamp < lastRun + interval) return;

        if (skipIfPaused) {
            if (_isPaused(address(vault)) || _isPaused(aggregator) || _isPaused(uniStrategy)) {
                lastRun = block.timestamp;
                emit OnUpkeepSkippedPaused(block.timestamp);
                return;
            }
        }

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

        address[] memory strategies = new address[](1);
        strategies[0] = uniStrategy;

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = uniPayload;

        bytes memory bundle = abi.encode(strategies, payloads);
        emit OnUpkeepAttempt(block.timestamp, idle, otherRatioBPS_, keccak256(bundle));

        try vault.investIntoStrategy(idle, strategies, payloads) returns (uint256 investedAssets) {
            emit OnInvestSucceeded(block.timestamp, idle, investedAssets, otherRatioBPS_);
        } catch (bytes memory reason) {
            emit OnInvestFailed(block.timestamp, reason);
        }
    }

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

        strategies = new address[](1);
        strategies[0] = uniStrategy;

        payloads = new bytes[](1);
        payloads[0] = uniPayload;

        bundle = abi.encode(strategies, payloads);
    }

    /**
     * @notice Builds UniV3 action payload expected by the strategy.
     * @dev Encoding matches strategy schema:
     *      `abi.encode(uint16, bytes, bytes, uint256, uint256, uint256)`.
     * @param _otherRatioBPS Target ratio in BPS.
     * @return ABI-encoded UniV3 action payload.
     */
    function _buildUniV3Payload(uint16 _otherRatioBPS) internal view returns (bytes memory) {
        bytes memory _swapToOtherData = _buildRankedSwapData(swapToOtherBPS);
        bytes memory _swapToUnderlyingData = _buildRankedSwapData(swapToUnderlyingBPS);

        uint256 _pmDeadline = deadlineBuffer == 0 ? 0 : block.timestamp + deadlineBuffer;

        return abi.encode(_otherRatioBPS, _swapToOtherData, _swapToUnderlyingData, _pmDeadline, minUnderlying, minOther);
    }

    /**
     * @notice Builds ranked fixed-route swap data with a BPS sentinel amount.
     * @dev Returns empty bytes when `bps_ == 0`.
     * @param _bps BPS sentinel for runtime amount calculation.
     * @return ABI-encoded ranked route swap payload.
     */
    function _buildRankedSwapData(uint16 _bps) internal pure returns (bytes memory) {
        if (_bps == 0) return bytes("");

        uint256 _amountIn = AMOUNT_IN_BPS_FLAG | uint256(_bps);
        uint8[2] memory routeIds;
        uint256[2] memory amountOutMins;
        routeIds[0] = ROUTE_V3_SINGLE_HOP;
        routeIds[1] = ROUTE_V4_SINGLE_HOP;

        return abi.encode(_amountIn, uint256(0), uint8(2), routeIds, amountOutMins);
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
        (uint160 _spotSqrtPriceX96,,,,,,) = pool.slot0();
        uint160 _ratioSqrtPriceX96 = _spotSqrtPriceX96;
        if (_ratioSqrtPriceX96 == 0) {
            uint32 _window = ISFUniV3StrategyAutomationView(uniStrategy).twapWindow();
            _ratioSqrtPriceX96 = _valuationSqrtPriceX96(_window);
        }

        int24 _tickLower = ISFUniV3StrategyAutomationView(uniStrategy).tickLower();
        int24 _tickUpper = ISFUniV3StrategyAutomationView(uniStrategy).tickUpper();

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
     * @notice Computes target other-token ratio for the current range/price.
     * @dev Uses unit-liquidity equivalent in-range composition.
     * @param _sqrtPriceX96 Current sqrt price in Q96.
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
     * @notice Authorizes contract upgrades.
     * @dev Required by UUPS; restricted to owner.
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
