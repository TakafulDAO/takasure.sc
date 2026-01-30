// SPDX-License-Identifier: GPL-3.0
import {ISFStrategyMaintenance} from "contracts/interfaces/saveFunds/ISFStrategyMaintenance.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

pragma solidity 0.8.28;

interface IUniswapV3PoolLike {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function tickSpacing() external view returns (int24);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract SaveFundsAutomationRunner is Ownable {
    IAddressManager immutable addressManager;

    // Config
    address public immutable aggregator;
    address public immutable uniStrategy;
    address public immutable pool;
    address public immutable underlyingToken; // SFUSDC in your case

    // interval-based gate
    uint256 public interval; // start at 4 hours
    uint256 public lastRun; // updated each performUpkeep attempt
    uint256 public deadlineBuffer; // e.g. 1 hour

    // tick band configuration
    int24 public offsetMult; // e.g. 10
    int24 public widthMult; // e.g. 200

    // mins
    uint256 public amount0Min;
    uint256 public amount1Min;

    // switches
    bool public paused;
    bool public skipIfPaused;
    bool public doRebalance;
    bool public doHarvest;

    // aggregator.harvest(data)
    bytes public harvestData;

    // Events
    event OnUpkeepAttempt(
        uint256 ts,
        int24 currentTick,
        int24 tickSpacing,
        bool token0IsUnderlying,
        int24 tickLower,
        int24 tickUpper,
        uint256 interval,
        uint256 deadlineBuffer
    );
    event OnUpkeepSkippedPaused(uint256 ts);
    event OnRebalanceSucceeded(uint256 ts, int24 tickLower, int24 tickUpper);
    event OnRebalanceFailed(uint256 ts, bytes reason);
    event OnHarvestSucceeded(uint256 ts);
    event OnHarvestFailed(uint256 ts, bytes reason);
    event OnConfigUpdated();

    // Errors
    error SaveFundsAutomationRunner__NotAddressZero();
    error SaveFundsAutomationRunner__TooSmall();
    error SaveFundsAutomationRunner__OutOfRange();
    error SaveFundsAutomationRunner__BadSpacing();
    error SaveFundsAutomationRunner__BadTicks();

    constructor(
        address _aggregator,
        address _uniStrategy,
        address _pool,
        address _underlyingToken, // SFUSDC
        uint256 _intervalSeconds,
        address _addressManager
    ) Ownable(msg.sender) {
        require(
            _aggregator != address(0) && _uniStrategy != address(0) && _pool != address(0)
                && _underlyingToken != address(0),
            SaveFundsAutomationRunner__NotAddressZero()
        );

        aggregator = _aggregator;
        uniStrategy = _uniStrategy;
        pool = _pool;
        underlyingToken = _underlyingToken;

        interval = _intervalSeconds;
        deadlineBuffer = 1 hours;

        offsetMult = 10;
        widthMult = 200;

        amount0Min = 0;
        amount1Min = 0;

        paused = false;
        skipIfPaused = true;
        doRebalance = true;
        doHarvest = true;
        harvestData = hex"";

        addressManager = IAddressManager(_addressManager);
    }

    // Owner setters
    function acceptKeeperRole() external {
        addressManager.acceptProposedRole(Roles.KEEPER);
    }

    function setInterval(uint256 newIntervalSeconds) external onlyOwner {
        require(newIntervalSeconds >= 5 minutes, SaveFundsAutomationRunner__TooSmall());
        interval = newIntervalSeconds;
        emit OnConfigUpdated();
    }

    function setPaused(bool v) external onlyOwner {
        paused = v;
        emit OnConfigUpdated();
    }

    function setSkipIfPaused(bool v) external onlyOwner {
        skipIfPaused = v;
        emit OnConfigUpdated();
    }

    function setActions(bool _doRebalance, bool _doHarvest) external onlyOwner {
        doRebalance = _doRebalance;
        doHarvest = _doHarvest;
        emit OnConfigUpdated();
    }

    function setDeadlineBuffer(uint256 newBuffer) external onlyOwner {
        require(newBuffer >= 60, SaveFundsAutomationRunner__TooSmall());
        deadlineBuffer = newBuffer;
        emit OnConfigUpdated();
    }

    function setTickMultipliers(int24 newOffsetMult, int24 newWidthMult) external onlyOwner {
        require(newOffsetMult > 0, SaveFundsAutomationRunner__OutOfRange());
        require(newWidthMult > 0, SaveFundsAutomationRunner__OutOfRange());
        offsetMult = newOffsetMult;
        widthMult = newWidthMult;
        emit OnConfigUpdated();
    }

    function setAmountMins(uint256 newAmount0Min, uint256 newAmount1Min) external onlyOwner {
        amount0Min = newAmount0Min;
        amount1Min = newAmount1Min;
        emit OnConfigUpdated();
    }

    function setHarvestData(bytes calldata data) external onlyOwner {
        harvestData = data;
        emit OnConfigUpdated();
    }

    function setLastRun(uint256 ts) external onlyOwner {
        lastRun = ts;
        emit OnConfigUpdated();
    }

    // Chainlink Keeper
    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (paused) return (false, bytes(""));
        if (block.timestamp < lastRun + interval) return (false, bytes(""));

        if (skipIfPaused) {
            if (_isPaused(aggregator) || _isPaused(uniStrategy)) return (false, bytes(""));
        }

        (int24 tickLower, int24 tickUpper, int24 currentTick, int24 spacing, bool token0IsUnderlying) = _computeTicks();

        // Encode what performUpkeep needs.
        performData = abi.encode(tickLower, tickUpper, currentTick, spacing, token0IsUnderlying);
        return (true, performData);
    }

    function performUpkeep(
        bytes calldata /* performData */
    )
        external
    {
        if (paused) return;
        if (block.timestamp < lastRun + interval) return;

        if (skipIfPaused) {
            if (_isPaused(aggregator) || _isPaused(uniStrategy)) {
                // still update lastRun to avoid spamming attempts every block
                lastRun = block.timestamp;
                emit OnUpkeepSkippedPaused(block.timestamp);
                return;
            }
        }

        lastRun = block.timestamp;

        (int24 tickLower, int24 tickUpper, int24 currentTick, int24 spacing, bool token0IsUnderlying) = _computeTicks();

        emit OnUpkeepAttempt(
            block.timestamp, currentTick, spacing, token0IsUnderlying, tickLower, tickUpper, interval, deadlineBuffer
        );

        // Build data for agg.rebalance: abi.encode(address[] strategies, bytes[] payloads)
        bytes memory rebalanceData = _buildRebalanceData(tickLower, tickUpper);

        // 1) Rebalance
        if (doRebalance) {
            try ISFStrategyMaintenance(aggregator).rebalance(rebalanceData) {
                emit OnRebalanceSucceeded(block.timestamp, tickLower, tickUpper);
            } catch (bytes memory reason) {
                emit OnRebalanceFailed(block.timestamp, reason);
            }
        }

        // 2) Harvest
        if (doHarvest) {
            try ISFStrategyMaintenance(aggregator).harvest(harvestData) {
                emit OnHarvestSucceeded(block.timestamp);
            } catch (bytes memory reason) {
                emit OnHarvestFailed(block.timestamp, reason);
            }
        }
    }

    // Internal functions
    function _computeTicks()
        internal
        view
        returns (int24 tickLower_, int24 tickUpper_, int24 currentTick_, int24 spacing_, bool token0IsUnderlying_)
    {
        IUniswapV3PoolLike _p = IUniswapV3PoolLike(pool);

        (, currentTick_,,,,,) = _p.slot0();
        spacing_ = _p.tickSpacing();

        require(spacing_ > 0, SaveFundsAutomationRunner__BadSpacing());

        address _token0 = _p.token0();
        token0IsUnderlying_ = (_token0 == underlyingToken);

        // offset = spacing * offsetMult ; width = spacing * widthMult
        int24 _offset = _toInt24(int256(spacing_) * int256(offsetMult));
        int24 _width = _toInt24(int256(spacing_) * int256(widthMult));

        if (token0IsUnderlying_) {
            tickLower_ = _ceilToSpacing(_toInt24(int256(currentTick_) + int256(_offset)), spacing_);
            tickUpper_ = _toInt24(int256(tickLower_) + int256(_width));
        } else {
            tickUpper_ = _floorToSpacing(_toInt24(int256(currentTick_) - int256(_offset)), spacing_);
            tickLower_ = _toInt24(int256(tickUpper_) - int256(_width));
        }

        require(tickLower_ < tickUpper_, SaveFundsAutomationRunner__BadTicks());
    }

    function _buildRebalanceData(int24 _tickLower, int24 _tickUpper) internal view returns (bytes memory) {
        // Uni strategy expects: (int24 lower, int24 upper, uint256 deadline, uint256 amount0Min, uint256 amount1Min)
        bytes memory _payload =
            abi.encode(_tickLower, _tickUpper, block.timestamp + deadlineBuffer, amount0Min, amount1Min);

        address[] memory _strategies = new address[](1);
        _strategies[0] = uniStrategy;

        bytes[] memory _payloads = new bytes[](1);
        _payloads[0] = _payload;
        // Aggregator expects: abi.encode(address[] strategies, bytes[] payloads)
        return abi.encode(_strategies, _payloads);
    }

    // Helpers
    function _isPaused(address _target) internal view returns (bool paused_) {
        (bool ok, bytes memory data) = _target.staticcall(abi.encodeWithSignature("paused()"));
        if (!ok || data.length < 32) return false;
        paused_ = abi.decode(data, (bool));
    }

    function _floorToSpacing(int24 _tick, int24 _spacing) internal pure returns (int24) {
        // floor(tick / spacing) * spacing   (spacing > 0)
        int24 q = _tick / _spacing; // rounds toward 0
        int24 r = _tick % _spacing;
        if (_tick < 0 && r != 0) q -= 1; // adjust to floor for negatives
        return _toInt24(int256(q) * int256(_spacing));
    }

    function _ceilToSpacing(int24 _tick, int24 _spacing) internal pure returns (int24) {
        // ceil(tick / spacing) * spacing   (spacing > 0)
        int24 q = _tick / _spacing; // rounds toward 0
        int24 r = _tick % _spacing;
        if (_tick > 0 && r != 0) q += 1; // adjust to ceil for positives
        // for negatives, division toward 0 is already ceil
        return _toInt24(int256(q) * int256(_spacing));
    }

    function _toInt24(int256 _x) internal pure returns (int24) {
        require(_x >= type(int24).min && _x <= type(int24).max, "INT24_OOB");
        return int24(_x);
    }
}
