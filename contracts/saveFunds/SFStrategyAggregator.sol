// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFStrategyAggregator
 * @author Maikel Ordaz
 * @notice Multi strategy aggregator for SaveFunds vaults.
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {ISFStrategyView} from "contracts/interfaces/saveFunds/ISFStrategyView.sol";
import {ISFStrategyMaintenance} from "contracts/interfaces/saveFunds/ISFStrategyMaintenance.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {StrategyConfig, SubStrategy} from "contracts/types/Strategies.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

pragma solidity 0.8.28;

contract SFStrategyAggregator is
    ISFStrategy,
    ISFStrategyView,
    ISFStrategyMaintenance,
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint16 private constant MAX_BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    IAddressManager public addressManager;
    IERC20 private underlying;

    EnumerableSet.AddressSet private subStrategySet;

    struct SubStrategyMeta {
        uint16 targetWeightBPS;
        bool isActive;
    }

    struct Bundle {
        address[] strategies;
        bytes[] payloads;
    }

    address public vault;

    uint16 public totalTargetWeightBPS; // sum of all target weights in BPS

    mapping(address strategy => SubStrategyMeta) private subStrategyMeta;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnSubStrategyAdded(address indexed strategy, uint16 targetWeightBPS, bool isActive);
    event OnSubStrategyUpdated(address indexed strategy, uint16 targetWeightBPS, bool isActive);
    event OnStrategyLossReported(
        uint256 requestedAssets,
        uint256 withdrawnAssets,
        uint256 prevTotalAssets,
        uint256 newTotalAssets,
        uint256 shortfall
    );

    error SFStrategyAggregator__NotAuthorizedCaller();
    error SFStrategyAggregator__NotAddressZero();
    error SFStrategyAggregator__InvalidConfig();
    error SFStrategyAggregator__InvalidTargetWeightBPS();
    error SFStrategyAggregator__DuplicateStrategy();
    error SFStrategyAggregator__NotZeroAmount();
    error SFStrategyAggregator__SubStrategyAlreadyExists();
    error SFStrategyAggregator__SubStrategyNotFound();
    error SFStrategyAggregator__StrategyNotAContract();
    error SFStrategyAggregator__InvalidStrategyAsset();
    error SFStrategyAggregator__InvalidPerStrategyData();
    error SFStrategyAggregator__UnknownPerStrategyDataStrategy();
    error SFStrategyAggregator__DuplicatePerStrategyDataStrategy();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyRole(bytes32 role) {
        require(addressManager.hasRole(role, msg.sender), SFStrategyAggregator__NotAuthorizedCaller());
        _;
    }

    modifier onlyKeeperOrOperator() {
        require(
            IAddressManager(addressManager).hasRole(Roles.KEEPER, msg.sender)
                || IAddressManager(addressManager).hasRole(Roles.OPERATOR, msg.sender),
            SFStrategyAggregator__NotAuthorizedCaller()
        );
        _;
    }

    modifier onlyContract(string memory name) {
        require(addressManager.hasName(name, msg.sender), SFStrategyAggregator__NotAuthorizedCaller());
        _;
    }

    modifier notAddressZero(address addr) {
        require(addr != address(0), SFStrategyAggregator__NotAddressZero());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IAddressManager _addressManager, IERC20 _asset, address _vault)
        external
        initializer
        notAddressZero(address(_addressManager))
        notAddressZero(address(_asset))
        notAddressZero(_vault)
    {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        __Pausable_init();

        addressManager = _addressManager;

        underlying = _asset;
        vault = _vault;
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets multiple sub-strategy configurations in a single call.
     * @dev Only callable by an OPERATOR. This call may add new strategies and/or update existing ones, then recomputes the active weight sum.
     * @param newConfig ABI-encoded config: abi.encode(address[] strategies, uint16[] weightsBps, bool[] actives).
     * @custom:invariant totalTargetWeightBPS == sum(targetWeightBPS of active strategies) and totalTargetWeightBPS <= 10_000.
     */
    function setConfig(bytes calldata newConfig) external onlyRole(Roles.OPERATOR) {
        (address[] memory strategies, uint16[] memory weights, bool[] memory actives) =
            abi.decode(newConfig, (address[], uint16[], bool[]));

        uint256 len = strategies.length;
        require(len != 0 && len == weights.length && len == actives.length, SFStrategyAggregator__InvalidConfig());

        for (uint256 i; i < len; ++i) {
            address s = strategies[i];

            require(s != address(0), SFStrategyAggregator__NotAddressZero());
            require(weights[i] <= MAX_BPS, SFStrategyAggregator__InvalidTargetWeightBPS());
            _assertChildStrategyCompatible(s);

            for (uint256 j = i + 1; j < len; ++j) {
                require(s != strategies[j], SFStrategyAggregator__DuplicateStrategy());
            }

            bool existed = subStrategySet.contains(s);
            if (!existed) {
                subStrategySet.add(s);
                subStrategyMeta[s] = SubStrategyMeta({targetWeightBPS: weights[i], isActive: actives[i]});
                emit OnSubStrategyAdded(s, weights[i], actives[i]);
            } else {
                subStrategyMeta[s].targetWeightBPS = weights[i];
                subStrategyMeta[s].isActive = actives[i];
                emit OnSubStrategyUpdated(s, weights[i], actives[i]);
            }
        }

        _recomputeTotalTargetWeightBPS();
    }

    /*//////////////////////////////////////////////////////////////
                               EMERGENCY
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyRole(Roles.PAUSE_GUARDIAN) {
        _pause();
    }

    function unpause() external onlyRole(Roles.PAUSE_GUARDIAN) {
        _unpause();
    }

    /**
     * @notice Attempts to withdraw all available funds from all child strategies and transfers them to `receiver`, then pauses the contract.
     * @dev Only callable by an OPERATOR. Uses each strategy’s `maxWithdraw()` to determine the maximum withdrawable amount.
     * @param receiver Address that will receive withdrawn assets and any idle balance held by the aggregator.
     * @custom:invariant paused() == true after the call completes.
     */
    function emergencyExit(address receiver) external notAddressZero(receiver) nonReentrant onlyRole(Roles.OPERATOR) {
        uint256 len = subStrategySet.length();

        for (uint256 i; i < len; ++i) {
            address s = subStrategySet.at(i);
            uint256 m = ISFStrategy(s).maxWithdraw();
            if (m == 0) continue;
            ISFStrategy(s).withdraw(m, receiver, bytes(""));
        }

        uint256 bal = underlying.balanceOf(address(this));
        if (bal > 0) underlying.safeTransfer(receiver, bal);

        _pause();
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allocates `assets` across active child strategies based on their target weights.
     * @dev Callable only by the allowlisted SaveFunds vault (`PROTOCOL__SF_VAULT`). Approves each strategy for its allocation and resets approvals to zero after each call.
     * @param assets Amount of underlying assets to allocate.
     * @param data ABI-encoded per-strategy payloads: abi.encode(address[] strategies, bytes[] payloads). Each payload is forwarded to the matching child strategy’s `deposit` call.
     * @return investedAssets Total amount actually invested by the child strategies (may be less than `assets`).
     * @custom:invariant investedAssets <= assets and any uninvested remainder is returned to `vault`.
     */
    function deposit(uint256 assets, bytes calldata data)
        external
        onlyContract("PROTOCOL__SF_VAULT")
        nonReentrant
        whenNotPaused
        returns (uint256 investedAssets)
    {
        address[] memory allocatableStrats = _allocatableSubStrategies();

        if (allocatableStrats.length == 0) {
            underlying.safeTransfer(vault, assets);
            return 0;
        }

        Bundle memory b = _decodeBundle(data);

        uint256 remainingAssets = assets;
        uint256 processedWeight;

        for (uint256 i; i < allocatableStrats.length && remainingAssets > 0; ++i) {
            address child = allocatableStrats[i];
            uint256 weight = uint256(subStrategyMeta[child].targetWeightBPS);

            uint256 remainingWeight = uint256(totalTargetWeightBPS) - processedWeight;

            // Last strategy gets all remaining assets (prevents dust / rounding leftovers)
            uint256 toAllocate =
                (i + 1 == allocatableStrats.length) ? remainingAssets : (remainingAssets * weight) / remainingWeight;

            processedWeight += weight;

            if (toAllocate == 0) continue;
            if (toAllocate > remainingAssets) toAllocate = remainingAssets;

            (uint256 childInvested, uint256 spent) = _depositIntoChild(child, toAllocate, b);

            investedAssets += childInvested;

            if (spent >= remainingAssets) break;
            remainingAssets -= spent;
        }

        uint256 leftover = underlying.balanceOf(address(this));
        if (leftover > 0) underlying.safeTransfer(vault, leftover);

        return investedAssets;
    }

    /**
     * @notice Withdraws up to `assets` of underlying to `receiver`, using idle funds first and then pulling from child strategies.
     * @dev Callable only by the allowlisted SaveFunds vault (`PROTOCOL__SF_VAULT`). If full withdrawal is not possible, emits a loss/illiquidity report.
     * @param assets Amount of underlying requested to withdraw.
     * @param receiver Address that will receive withdrawn underlying.
     * @param data ABI-encoded per-strategy payloads: abi.encode(address[] strategies, bytes[] payloads). Each payload is forwarded to the matching child strategy’s `withdraw` call.
     * @return withdrawnAssets Amount of underlying actually withdrawn and transferred to `receiver` (may be less than `assets`).
     * @custom:invariant withdrawnAssets <= assets and transfers to `receiver` equal withdrawnAssets.
     */
    function withdraw(uint256 assets, address receiver, bytes calldata data)
        external
        notAddressZero(receiver)
        nonReentrant
        whenNotPaused
        onlyContract("PROTOCOL__SF_VAULT")
        returns (uint256 withdrawnAssets)
    {
        require(assets > 0, SFStrategyAggregator__NotZeroAmount());

        // snapshot before moving anything
        uint256 prevTotalAssets = totalAssets();

        (address[] memory dataStrategies, bytes[] memory perChildData) = _decodePerStrategyData(data);

        // 1) use idle funds first
        withdrawnAssets = _useIdleFunds(receiver, assets);

        // 2) then withdraw from children if still needed
        if (withdrawnAssets < assets) {
            withdrawnAssets += _withdrawFromSubStrategies(
                receiver, assets - withdrawnAssets, dataStrategies, perChildData
            );
        }

        // 3) loss/illiquidity report
        if (withdrawnAssets < assets) {
            _reportLoss(assets, withdrawnAssets, prevTotalAssets);
        }

        return withdrawnAssets;
    }

    /*//////////////////////////////////////////////////////////////
                              MAINTENANCE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calls `harvest` on child strategies.
     * @dev Callable only by a KEEPER or OPERATOR. If `data` is empty, harvests all active strategies with an empty payload; otherwise, harvests the specified strategies with provided payloads.
     * @param data If non-empty, ABI-encoded per-strategy payloads: abi.encode(address[] strategies, bytes[] payloads).
     * @custom:invariant Does not modify strategy configuration (set membership or target weights).
     */
    function harvest(bytes calldata data) external nonReentrant whenNotPaused onlyKeeperOrOperator {
        // No data => harvest all active strategies with empty payload
        if (data.length == 0) {
            uint256 len = subStrategySet.length();
            for (uint256 i; i < len; ++i) {
                address stratAddr = subStrategySet.at(i);
                if (!subStrategyMeta[stratAddr].isActive) continue;
                ISFStrategyMaintenance(stratAddr).harvest(bytes(""));
            }
            return;
        }

        // Data => allowlist + per-strategy payload
        (address[] memory strategies, bytes[] memory payloads) = _decodePerStrategyData(data);

        for (uint256 i; i < strategies.length; ++i) {
            ISFStrategyMaintenance(strategies[i]).harvest(payloads[i]);
        }
    }

    /**
     * @notice Calls `rebalance` on child strategies.
     * @dev Callable only by a KEEPER or OPERATOR. If `data` is empty, rebalances all active strategies with an empty payload; otherwise, rebalances the specified strategies with provided payloads.
     * @param data If non-empty, ABI-encoded per-strategy payloads: abi.encode(address[] strategies, bytes[] payloads).
     * @custom:invariant Does not modify strategy configuration (set membership or target weights).
     */
    function rebalance(bytes calldata data) external nonReentrant whenNotPaused onlyKeeperOrOperator {
        // No data => rebalance all active strategies with empty payload
        if (data.length == 0) {
            uint256 len = subStrategySet.length();
            for (uint256 i; i < len; ++i) {
                address stratAddr = subStrategySet.at(i);
                if (!subStrategyMeta[stratAddr].isActive) continue;
                ISFStrategyMaintenance(stratAddr).rebalance(bytes(""));
            }
            return;
        }

        (address[] memory strategies, bytes[] memory payloads) = _decodePerStrategyData(data);

        for (uint256 i; i < strategies.length; ++i) {
            if (!subStrategyMeta[strategies[i]].isActive) continue;
            ISFStrategyMaintenance(strategies[i]).rebalance(payloads[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           SUB-STRATEGY MGMT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds a new child strategy and activates it.
     * @dev Only callable by an OPERATOR. The child strategy must be a contract and must manage the same `asset()` as the aggregator.
     * @param strategy Address of the child strategy to add.
     * @param targetWeightBPS Target allocation weight in basis points (0..10_000).
     * @custom:invariant strategy is included in the set exactly once and totalTargetWeightBPS <= 10_000 after recomputation.
     */
    function addSubStrategy(address strategy, uint16 targetWeightBPS)
        external
        notAddressZero(strategy)
        onlyRole(Roles.OPERATOR)
    {
        _assertChildStrategyCompatible(strategy);
        require(targetWeightBPS > 0 && targetWeightBPS <= MAX_BPS, SFStrategyAggregator__InvalidTargetWeightBPS());
        require(subStrategySet.add(strategy), SFStrategyAggregator__SubStrategyAlreadyExists());

        subStrategyMeta[strategy] = SubStrategyMeta({targetWeightBPS: targetWeightBPS, isActive: true});

        _recomputeTotalTargetWeightBPS();
        emit OnSubStrategyAdded(strategy, targetWeightBPS, true);
    }

    /**
     * @notice Updates an existing child strategy’s weight and active status.
     * @dev Only callable by an OPERATOR. Recomputes active weight sum after updating.
     * @param strategy Address of the child strategy to update.
     * @param targetWeightBPS New target allocation weight in basis points (0..10_000).
     * @param isActive Whether the strategy should be considered active for allocations.
     * @custom:invariant totalTargetWeightBPS == sum(targetWeightBPS of active strategies) and totalTargetWeightBPS <= 10_000.
     */
    function updateSubStrategy(address strategy, uint16 targetWeightBPS, bool isActive)
        external
        notAddressZero(strategy)
        onlyRole(Roles.OPERATOR)
    {
        require(subStrategySet.contains(strategy), SFStrategyAggregator__SubStrategyNotFound());
        require(targetWeightBPS <= MAX_BPS, SFStrategyAggregator__InvalidTargetWeightBPS());

        if (isActive) require(targetWeightBPS > 0, SFStrategyAggregator__InvalidTargetWeightBPS());
        else require(targetWeightBPS == 0, SFStrategyAggregator__InvalidTargetWeightBPS());

        subStrategyMeta[strategy].targetWeightBPS = targetWeightBPS;
        subStrategyMeta[strategy].isActive = isActive;

        _recomputeTotalTargetWeightBPS();
        emit OnSubStrategyUpdated(strategy, targetWeightBPS, isActive);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the underlying asset managed by this aggregator and all child strategies.
     * @dev Child strategies are required to return this same asset from their `asset()` function.
     * @return asset_ Address of the underlying ERC20 asset.
     * @custom:invariant Returned asset_ equals the `underlying` stored in this contract.
     */
    function asset() external view returns (address) {
        return address(underlying);
    }

    /**
     * @notice Returns the maximum amount of underlying that could be withdrawn right now.
     * @dev Computed as idle balance plus the sum of each child strategy’s `maxWithdraw()`.
     * @return maxAssets Maximum withdrawable amount in underlying units.
     * @custom:invariant maxAssets equals underlying.balanceOf(this) + Σ strategy.maxWithdraw().
     */
    function maxWithdraw() external view returns (uint256) {
        uint256 sum = underlying.balanceOf(address(this));

        uint256 len = subStrategySet.length();
        for (uint256 i; i < len; ++i) {
            sum += ISFStrategy(subStrategySet.at(i)).maxWithdraw();
        }

        return sum;
    }

    /**
     * @notice Returns high-level configuration metadata for this aggregator.
     * @dev The returned config is intended for off-chain introspection (frontends, monitoring, etc.).
     * @return config StrategyConfig with fields: asset, vault, pool (0 for aggregator),  paused.
     */
    function getConfig() external view returns (StrategyConfig memory) {
        return StrategyConfig({
            asset: address(underlying),
            vault: vault,
            pool: address(0), // aggregator has no single pool
            paused: paused()
        });
    }

    /**
     * @notice Returns the total value held in child strategies (excluding idle funds held by the aggregator).
     * @dev Sums `totalAssets()` from all registered child strategies, regardless of active status.
     * @return value Total underlying value held inside child strategies.
     * @custom:invariant value <= totalAssets().
     */
    function positionValue() external view returns (uint256) {
        uint256 sum;
        uint256 len = subStrategySet.length();

        for (uint256 i; i < len; ++i) {
            sum += ISFStrategy(subStrategySet.at(i)).totalAssets();
        }

        return sum;
    }

    /**
     * @notice Returns an encoded snapshot of the sub-strategy configuration.
     * @dev Intended for off-chain consumers. The encoding mirrors the `setConfig` input arrays.
     * @return details ABI-encoded value: abi.encode(address[] strategies, uint16[] weightsBps, bool[] actives).
     * @custom:invariant Decoded arrays have equal length and correspond to the current subStrategySet iteration order.
     */
    function getPositionDetails() external view returns (bytes memory) {
        uint256 len = subStrategySet.length();

        address[] memory strategies = new address[](len);
        uint16[] memory weights = new uint16[](len);
        bool[] memory actives = new bool[](len);

        for (uint256 i; i < len; ++i) {
            address s = subStrategySet.at(i);
            SubStrategyMeta memory m = subStrategyMeta[s];

            strategies[i] = s;
            weights[i] = m.targetWeightBPS;
            actives[i] = m.isActive;
        }

        return abi.encode(strategies, weights, actives);
    }

    /**
     * @notice Returns the list of sub-strategies with their weights and active flags.
     * @dev Convenience view that expands the internal set into an array of `SubStrategy`.
     * @return out Array of SubStrategy { strategy, targetWeightBPS, isActive }.
     * @custom:invariant out.length == subStrategySet.length().
     */
    function getSubStrategies() external view returns (SubStrategy[] memory out) {
        uint256 len = subStrategySet.length();
        out = new SubStrategy[](len);

        for (uint256 i; i < len; ++i) {
            address s = subStrategySet.at(i);
            SubStrategyMeta memory m = subStrategyMeta[s];

            out[i] = SubStrategy({strategy: ISFStrategy(s), targetWeightBPS: m.targetWeightBPS, isActive: m.isActive});
        }
    }

    /**
     * @notice Returns the total underlying managed by the aggregator, including idle funds and all child strategies.
     * @dev Sums this contract’s underlying balance plus each child strategy’s `totalAssets()`.
     * @return total Total underlying assets under management.
     * @custom:invariant total == underlying.balanceOf(this) + Σ strategy.totalAssets().
     */
    function totalAssets() public view returns (uint256) {
        uint256 sum = underlying.balanceOf(address(this));
        uint256 len = subStrategySet.length();

        for (uint256 i; i < len; ++i) {
            sum += ISFStrategy(subStrategySet.at(i)).totalAssets();
        }
        return sum;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Validates that `_strategy` is a contract and that its `asset()` matches this aggregator’s underlying.
     * @param _strategy Child strategy address to validate.
     * @custom:invariant If this function does not revert, then ISFStrategyView(_strategy).asset() == asset().
     */
    function _assertChildStrategyCompatible(address _strategy) internal view {
        require(_strategy.code.length != 0, SFStrategyAggregator__StrategyNotAContract());

        (bool ok, bytes memory returnData) = _strategy.staticcall(abi.encodeWithSignature("asset()"));
        require(ok && returnData.length >= 32, SFStrategyAggregator__InvalidStrategyAsset());

        address stratAsset = abi.decode(returnData, (address));
        require(stratAsset == address(underlying), SFStrategyAggregator__InvalidStrategyAsset());
    }

    /**
     * @dev Recomputes `totalTargetWeightBPS` as the sum of active sub-strategy target weights.
     * @custom:invariant totalTargetWeightBPS <= 10_000.
     */
    function _recomputeTotalTargetWeightBPS() internal {
        uint256 len = subStrategySet.length();
        uint256 sum;

        for (uint256 i; i < len; ++i) {
            address s = subStrategySet.at(i);
            SubStrategyMeta memory m = subStrategyMeta[s];
            if (m.isActive) sum += m.targetWeightBPS;
        }

        require(sum <= MAX_BPS, SFStrategyAggregator__InvalidTargetWeightBPS());
        totalTargetWeightBPS = uint16(sum);
    }

    /**
     * @dev Returns the list of strategies that are actually eligible to receive allocations: active + targetWeightBPS > 0.
     */
    function _allocatableSubStrategies() internal view returns (address[] memory strategies_) {
        uint256 len = subStrategySet.length();

        uint256 count;
        for (uint256 i; i < len; ++i) {
            address strat = subStrategySet.at(i);
            SubStrategyMeta memory m = subStrategyMeta[strat];
            if (m.isActive && m.targetWeightBPS != 0) ++count;
        }

        strategies_ = new address[](count);
        uint256 index;

        for (uint256 i; i < len; ++i) {
            address strat = subStrategySet.at(i);
            SubStrategyMeta memory m = subStrategyMeta[strat];
            if (m.isActive && m.targetWeightBPS != 0) strategies_[index++] = strat;
        }
    }

    function _decodeBundle(bytes calldata _data) internal pure returns (Bundle memory b_) {
        if (_data.length == 0) {
            b_.strategies = new address[](0);
            b_.payloads = new bytes[](0);
            return b_;
        }

        (b_.strategies, b_.payloads) = abi.decode(_data, (address[], bytes[]));
    }

    function _depositIntoChild(address _child, uint256 _toAllocate, Bundle memory _b)
        internal
        returns (uint256 childInvested_, uint256 actualSpent_)
    {
        uint256 balanceBefore = underlying.balanceOf(address(this));

        underlying.forceApprove(_child, _toAllocate);
        bytes memory childData = _payloadFor(_child, _b.strategies, _b.payloads);
        childInvested_ = ISFStrategy(_child).deposit(_toAllocate, childData);

        underlying.forceApprove(_child, 0);

        uint256 balanceAfter = underlying.balanceOf(address(this));
        actualSpent_ = balanceAfter < balanceBefore ? (balanceBefore - balanceAfter) : 0;
    }

    /**
     * @dev Decodes and validates the per-strategy payload bundle.
     * @param _data ABI-encoded value: abi.encode(address[] strategies, bytes[] payloads).
     * @return strategies_ List of strategy addresses referenced by the payload bundle.
     * @return payloads_ Per-strategy payloads aligned by index with `strategies_`.
     * @custom:invariant strategies_.length == payloads_.length and strategies_ has no duplicates and every strategy is registered.
     */
    function _decodePerStrategyData(bytes calldata _data)
        internal
        view
        returns (address[] memory strategies_, bytes[] memory payloads_)
    {
        if (_data.length == 0) {
            strategies_ = new address[](0);
            payloads_ = new bytes[](0);
        }

        (strategies_, payloads_) = abi.decode(_data, (address[], bytes[]));
        require(strategies_.length == payloads_.length, SFStrategyAggregator__InvalidPerStrategyData());

        // validate no duplicates + all strategies exist in current sub-strategies
        uint256 len = strategies_.length;
        for (uint256 i; i < len; ++i) {
            address strat = strategies_[i];
            require(strat != address(0), SFStrategyAggregator__NotAddressZero());
            require(subStrategySet.contains(strat), SFStrategyAggregator__UnknownPerStrategyDataStrategy());

            for (uint256 j = i + 1; j < len; ++j) {
                require(strat != strategies_[j], SFStrategyAggregator__DuplicatePerStrategyDataStrategy());
            }
        }
    }

    /**
     * @dev Returns the payload for `_strategy` from the provided arrays (or empty bytes if not present).
     * @param _strategy Strategy to look up.
     * @param _strategies Strategy addresses in the payload bundle.
     * @param _payloads Payloads aligned to `_strategies` by index.
     * @return payload Payload for `_strategy` (or bytes("")).
     * @custom:invariant If `_strategy` is present in `_strategies`, the returned payload equals the corresponding entry in `_payloads`.
     */
    function _payloadFor(address _strategy, address[] memory _strategies, bytes[] memory _payloads)
        internal
        pure
        returns (bytes memory)
    {
        for (uint256 i; i < _strategies.length; ++i) {
            if (_strategies[i] == _strategy) return _payloads[i];
        }
        return bytes("");
    }

    /**
     * @dev Transfers up to `remaining` of idle underlying held by the aggregator to `receiver`.
     * @param receiver Address receiving idle funds.
     * @param remaining Maximum amount to send.
     * @return sent Amount actually transferred from idle balance.
     * @custom:invariant sent <= remaining.
     */
    function _useIdleFunds(address receiver, uint256 remaining) internal returns (uint256 sent) {
        uint256 idle = underlying.balanceOf(address(this));
        if (idle == 0) return 0;

        sent = idle > remaining ? remaining : idle;
        underlying.safeTransfer(receiver, sent);
    }

    /**
     * @dev Attempts to pull underlying from child strategies until `_remaining` is satisfied or liquidity is exhausted.
     * @param _receiver Address receiving the withdrawn underlying.
     * @param _remaining Amount still needed to satisfy the overall withdrawal request.
     * @param _dataStrategies Strategy addresses referenced by the payload bundle.
     * @param _perChildData Payloads aligned to `_dataStrategies` by index.
     * @return sent_ Total amount transferred to `_receiver` during this call.
     * @custom:invariant sent_ <= _remaining.
     */
    function _withdrawFromSubStrategies(
        address _receiver,
        uint256 _remaining,
        address[] memory _dataStrategies,
        bytes[] memory _perChildData
    ) internal returns (uint256 sent_) {
        uint256 len = subStrategySet.length();

        for (uint256 i; i < len && sent_ < _remaining; ++i) {
            address stratAddr = subStrategySet.at(i);

            uint256 maxW = ISFStrategy(stratAddr).maxWithdraw();
            if (maxW == 0) continue;

            uint256 toAsk = maxW > (_remaining - sent_) ? (_remaining - sent_) : maxW;
            if (toAsk == 0) continue;

            uint256 got = ISFStrategy(stratAddr)
                .withdraw(toAsk, address(this), _payloadFor(stratAddr, _dataStrategies, _perChildData));
            if (got == 0) continue;

            underlying.safeTransfer(_receiver, got);
            sent_ += got;
        }
    }

    /**
     * @dev Emits a loss/illiquidity report event when the requested withdrawal could not be fully satisfied.
     * @param requestedAssets Amount of underlying originally requested.
     * @param withdrawnAssets Amount of underlying actually withdrawn.
     * @param prevTotalAssets Snapshot of `totalAssets()` taken before attempting the withdrawal.
     * @custom:invariant withdrawnAssets <= requestedAssets.
     */
    function _reportLoss(uint256 requestedAssets, uint256 withdrawnAssets, uint256 prevTotalAssets) internal {
        uint256 newTotalAssets = totalAssets();
        uint256 shortfall = requestedAssets - withdrawnAssets;

        emit OnStrategyLossReported(requestedAssets, withdrawnAssets, prevTotalAssets, newTotalAssets, shortfall);
    }

    /// @dev required by the OZ UUPS module.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.OPERATOR) {}
}
