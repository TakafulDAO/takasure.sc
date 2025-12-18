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

    IAddressManager public addressManager;

    IERC20 private underlying;

    SubStrategy[] private subStrategies;

    address public vault;

    uint256 public maxTVL;
    uint16 public totalTargetWeightBPS; // sum of all target weights in BPS

    // TODO: consider using EnumerableMap for easier management
    mapping(address strat => uint256) private subStrategyIndex; // strategy => index + 1

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint16 private constant MAX_BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnMaxTVLUpdated(uint256 oldMaxTVL, uint256 newMaxTVL);
    event OnSubStrategyAdded(address indexed strategy, uint16 targetWeightBPS, bool isActive);
    event OnSubStrategyUpdated(address indexed strategy, uint16 targetWeightBPS, bool isActive);
    event OnStrategyLossReported(uint256 prevAssets, uint256 newAssets, uint256 lossAmount);

    error SFStrategyAggregator__NotAuthorizedCaller();
    error SFStrategyAggregator__InvalidTargetWeightBPS();
    error SFStrategyAggregator__SubStrategyAlreadyExists();
    error SFStrategyAggregator__SubStrategyNotFound();
    error SFStrategyAggregator__NotZeroAmount();
    error SFStrategyAggregator__NotAddressZero();
    error SFStrategyAggregator__InvalidConfig();
    error SFStrategyAggregator__DuplicateStrategy();
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

    function initialize(IAddressManager _addressManager, IERC20 _asset, uint256 _maxTVL, address _vault)
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
        maxTVL = _maxTVL;
        vault = _vault;
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    function setMaxTVL(uint256 newMaxTVL) external onlyRole(Roles.OPERATOR) {
        uint256 oldMaxTVL = maxTVL;
        maxTVL = newMaxTVL;
        emit OnMaxTVLUpdated(oldMaxTVL, newMaxTVL);
    }

    /**
     * @notice Sets the configuration of multiple sub-strategies at once.
     * @param newConfig Encoded configuration data containing arrays of strategies, weights, and active statuses. abi.encode(addresses, weightsBps, actives)
     */
    function setConfig(bytes calldata newConfig) external onlyRole(Roles.OPERATOR) {
        (address[] memory strategies, uint16[] memory weights, bool[] memory actives) =
            abi.decode(newConfig, (address[], uint16[], bool[]));

        uint256 len = strategies.length;
        require(len != 0 && len == weights.length && len == actives.length, SFStrategyAggregator__InvalidConfig());

        // Validate entries + no duplicates O(n^2) - acceptable as only will be two strategies
        for (uint256 i; i < len; ++i) {
            address strat = strategies[i];
            require(strat != address(0), SFStrategyAggregator__NotAddressZero());
            require(weights[i] <= MAX_BPS, SFStrategyAggregator__InvalidTargetWeightBPS());
            _assertChildStrategyCompatible(strat);

            for (uint256 j = i + 1; j < len; ++j) {
                require(strat != strategies[j], SFStrategyAggregator__DuplicateStrategy());
            }
        }

        // Compute the final totalTargetWeightBPS only once to avoid intermediate-sum reverts
        int256 projectedTotal = int256(uint256(totalTargetWeightBPS));

        for (uint256 i; i < len; ++i) {
            address s = strategies[i];
            uint16 w = weights[i];
            bool a = actives[i];

            uint256 idxPlus = subStrategyIndex[s];
            uint256 oldEff;

            if (idxPlus != 0) {
                SubStrategy storage existing = subStrategies[idxPlus - 1];
                oldEff = existing.isActive ? existing.targetWeightBPS : 0;
            }

            uint128 newEff = a ? w : 0;
            projectedTotal += int256(uint256(newEff)) - int256(uint256(oldEff));
        }

        require(
            projectedTotal >= 0 && projectedTotal <= int256(uint256(MAX_BPS)),
            SFStrategyAggregator__InvalidTargetWeightBPS()
        );

        // Apply changes
        for (uint256 i; i < len; ++i) {
            address s = strategies[i];
            uint16 w = weights[i];
            bool a = actives[i];

            uint256 idxPlus = subStrategyIndex[s];

            if (idxPlus == 0) {
                // New strategy
                subStrategies.push(SubStrategy({strategy: ISFStrategy(s), targetWeightBPS: w, isActive: a}));
                subStrategyIndex[s] = subStrategies.length; // index + 1
                emit OnSubStrategyAdded(s, w, a);
            } else {
                // Existing strategy
                SubStrategy storage existing = subStrategies[idxPlus - 1];
                existing.targetWeightBPS = w;
                existing.isActive = a;
                emit OnSubStrategyUpdated(s, w, a);
            }
        }

        totalTargetWeightBPS = uint16(uint256(projectedTotal));
        assert(totalTargetWeightBPS <= MAX_BPS);
    }

    /*//////////////////////////////////////////////////////////////
                           SUB-STRATEGY MGMT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds new child strategy to the aggregator.
     * @param strategy Address of the child strategy.
     * @param targetWeightBPS Target weight in basis points (0 to 10000).
     */
    function addSubStrategy(address strategy, uint16 targetWeightBPS)
        external
        notAddressZero(strategy)
        onlyRole(Roles.OPERATOR)
    {
        _assertChildStrategyCompatible(strategy);

        require(subStrategyIndex[strategy] == 0, SFStrategyAggregator__SubStrategyAlreadyExists());
        require(totalTargetWeightBPS + targetWeightBPS <= MAX_BPS, SFStrategyAggregator__InvalidTargetWeightBPS());

        // By default every strategy is active.
        subStrategies.push(
            SubStrategy({strategy: ISFStrategy(strategy), targetWeightBPS: targetWeightBPS, isActive: true})
        );
        subStrategyIndex[strategy] = subStrategies.length; // index + 1

        totalTargetWeightBPS += targetWeightBPS;
        assert(totalTargetWeightBPS <= MAX_BPS);

        emit OnSubStrategyAdded(strategy, targetWeightBPS, true);
    }

    /**
     * @notice Updates an existing child strategy's configuration.
     * @param strategy Address of the child strategy to update.
     * @param targetWeightBPS New target weight in basis points (0 to 10000).
     * @param isActive New active status of the strategy.
     */
    function updateSubStrategy(address strategy, uint16 targetWeightBPS, bool isActive)
        external
        notAddressZero(strategy)
        onlyRole(Roles.OPERATOR)
    {
        require(subStrategyIndex[strategy] != 0, SFStrategyAggregator__SubStrategyNotFound());

        uint256 index = subStrategyIndex[strategy] - 1;
        SubStrategy storage strat = subStrategies[index];

        // Only count old one if strategy was active. Only count new one if strategy will be active
        uint16 oldEffectiveWeight = strat.isActive ? strat.targetWeightBPS : 0;
        uint16 newEffectiveWeight = isActive ? targetWeightBPS : 0;

        // Remove old effective weight from the total
        totalTargetWeightBPS = totalTargetWeightBPS - oldEffectiveWeight;
        require(totalTargetWeightBPS + newEffectiveWeight <= MAX_BPS, SFStrategyAggregator__InvalidTargetWeightBPS());

        strat.targetWeightBPS = targetWeightBPS;
        strat.isActive = isActive;

        totalTargetWeightBPS = totalTargetWeightBPS + newEffectiveWeight;
        assert(totalTargetWeightBPS <= MAX_BPS);

        emit OnSubStrategyUpdated(strategy, targetWeightBPS, isActive);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits assets into the aggregator, which allocates them to child strategies based on target weights.
     * @param assets Amount of underlying assets to deposit.
     * @param data Additional data for deposit (not used in this implementation).
     * @return investedAssets Total amount of assets successfully invested into child strategies.
     */
    function deposit(uint256 assets, bytes calldata data)
        external
        onlyContract("PROTOCOL__SF_VAULT")
        nonReentrant
        whenNotPaused
        returns (uint256 investedAssets)
    {
        require(assets > 0, SFStrategyAggregator__NotZeroAmount());

        uint256 len = subStrategies.length;

        // If there is no substrategies yet, return the funds to to the vault
        if (len == 0) {
            underlying.safeTransfer(vault, assets);
            return 0;
        }

        // interpret data: abi.encode(address[] strategies, bytes[] perChildData)
        (address[] memory dataStrategies, bytes[] memory perChildData) = _decodePerStrategyData(data);

        uint256 remaining = assets;

        for (uint256 i; i < len; ++i) {
            SubStrategy memory strat = subStrategies[i];

            if (strat.isActive) {
                uint256 toAllocate = (assets * strat.targetWeightBPS) / MAX_BPS;

                if (toAllocate == 0) continue;
                if (toAllocate > remaining) toAllocate = remaining;

                // Forward funds to child strategy
                // TODO: check if safeIncreaseAllowance is better. Revisit.
                underlying.forceApprove(address(strat.strategy), toAllocate);

                bytes memory childData = _payloadFor(address(strat.strategy), dataStrategies, perChildData);

                // TODO: revisit this to check the best way to interact with both v3 and v4 strategies. This for the data param
                uint256 childInvested = strat.strategy.deposit(toAllocate, childData);

                investedAssets += childInvested;
                remaining -= toAllocate;

                if (remaining == 0) break;
            }
        }

        // Any unnalocated tokens must not stay in the aggregator long term.
        // Send back to the vault.
        // TODO: To discuss: Check if better instead of sending to vault, route remaining to a "buffer" strategy or something like that? Revisit
        if (remaining > 0) underlying.safeTransfer(vault, remaining);

        return investedAssets;
    }

    /**
     * @notice Withdraws assets from the aggregator, pulling from idle funds first and then from child strategies as needed.
     * @param assets Amount of underlying assets to withdraw.
     * @param receiver Address to receive the withdrawn assets.
     * @param data Additional data for withdrawal (not used in this implementation).
     * @return withdrawnAssets Total amount of assets successfully withdrawn.
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

        uint256 remaining = assets;

        // Use idle funds first.
        uint256 idle = underlying.balanceOf(address(this));
        if (idle > 0) {
            uint256 toSend = idle > remaining ? remaining : idle;
            underlying.safeTransfer(receiver, toSend);
            withdrawnAssets += toSend;
            remaining -= toSend;
        }

        if (remaining == 0) return withdrawnAssets;

        // Withdraw from subStrategies.
        uint256 len = subStrategies.length;

        for (uint256 i; i < len && remaining > 0; ++i) {
            SubStrategy memory strat = subStrategies[i];

            if (strat.isActive) {
                uint256 subStratMax = strat.strategy.maxWithdraw();
                if (subStratMax == 0) continue;

                uint256 toAsk = subStratMax > remaining ? remaining : subStratMax;
                if (toAsk == 0) continue;

                // TODO: revisit this to check the best way to interact with both v3 and v4 strategies. This for the data param
                uint256 childGot = strat.strategy.withdraw(toAsk, address(this), bytes(""));
                if (childGot == 0) continue;

                // Immediately pass to receiver
                underlying.safeTransfer(receiver, childGot);
                withdrawnAssets += childGot;

                if (childGot >= remaining) {
                    remaining = 0;
                    break;
                } else {
                    remaining -= childGot;
                }
            }
        }

        // If we still need more assets, it is a loss or illiquidity situation.
        if (withdrawnAssets < assets) {
            uint256 prevAssets = assets; // TODO: maybe snapshot before withdraw? check
            uint256 newAssets = totalAssets();
            uint256 lossAmount = assets - withdrawnAssets;
            emit OnStrategyLossReported(prevAssets, newAssets, lossAmount);
        }

        return withdrawnAssets;
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
     * @notice Emergency exit function to withdraw all assets from child strategies and transfer to a receiver.
     * @param receiver Address to receive all withdrawn assets.
     */
    function emergencyExit(address receiver) external notAddressZero(receiver) nonReentrant onlyRole(Roles.OPERATOR) {
        // Pull everything from subStrategies to the receiver.
        uint256 len = subStrategies.length;

        for (uint256 i; i < len; ++i) {
            SubStrategy memory strat = subStrategies[i];

            if (strat.isActive) {
                uint256 subStratMax = strat.strategy.maxWithdraw();
                if (subStratMax == 0) continue;

                strat.strategy.withdraw(subStratMax, receiver, "");
            }
        }

        // Transfer idle funds to receiver
        uint256 balance = underlying.balanceOf(address(this));
        if (balance > 0) underlying.safeTransfer(receiver, balance);

        _pause();
    }

    /*//////////////////////////////////////////////////////////////
                              MAINTENANCE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Harvests rewards from all active child strategies.
     * @param data Additional data for harvesting (not used in this implementation).
     */
    function harvest(bytes calldata data) external nonReentrant whenNotPaused onlyKeeperOrOperator {
        // TODO: include in data the children to harvest?
        uint256 len = subStrategies.length;

        for (uint256 i; i < len; ++i) {
            SubStrategy memory strat = subStrategies[i];

            // TODO: revisit this to check the best way to interact with both v3 and v4 strategies. This for the data param
            if (strat.isActive) ISFStrategyMaintenance(address(strat.strategy)).harvest(bytes(""));
        }
    }

    /**
     * @notice Rebalances all active child strategies.
     * @param data Additional data for rebalancing (not used in this implementation).
     */
    function rebalance(bytes calldata data) external nonReentrant whenNotPaused onlyKeeperOrOperator {
        // TODO: finish this function
        uint256 len = subStrategies.length;

        for (uint256 i; i < len; ++i) {
            SubStrategy memory strat = subStrategies[i];

            // TODO: revisit this to check the best way to interact with both v3 and v4 strategies. This for the data param
            if (strat.isActive) ISFStrategyMaintenance(address(strat.strategy)).rebalance(data);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the underlying asset address managed by the strategy.
     * @return Address of the underlying asset.
     */
    function asset() external view returns (address) {
        return address(underlying);
    }

    /**
     * @notice Returns the total assets managed by the aggregator, including all active child strategies.
     * @return Total assets under management.
     */
    function totalAssets() public view returns (uint256) {
        // Aggregator should not hold idle assets at rest, all value is expected to live in sub-strategies.
        // uint256 sum = underlying.balanceOf(address(this));

        uint256 sum;

        uint256 len = subStrategies.length;

        for (uint256 i; i < len; ++i) {
            SubStrategy memory strat = subStrategies[i];

            if (strat.isActive) sum += strat.strategy.totalAssets();
        }

        return sum;
    }

    /**
     * @notice Returns the maximum deposit amount allowed by the aggregator.
     * @return Maximum deposit amount.
     */
    function maxDeposit() external view returns (uint256) {
        // 0 means no cap
        if (maxTVL == 0) return type(uint256).max;

        uint256 current = totalAssets();
        if (current >= maxTVL) return 0;
        return maxTVL - current;
    }

    /**
     * @notice Returns the maximum withdrawable amount from the aggregator.
     * @return Maximum withdrawable amount.
     */
    function maxWithdraw() external view returns (uint256) {
        // TODO: check
        return totalAssets();
    }

    function getConfig() external view returns (StrategyConfig memory) {
        return StrategyConfig({
            asset: address(underlying),
            vault: vault,
            pool: address(0), // aggregator has no single pool
            maxTVL: maxTVL,
            paused: paused()
        });
    }

    function positionValue() external view returns (uint256) {
        // For aggregator, "position" = children (no idle).
        uint256 sum;

        uint256 len = subStrategies.length;

        for (uint256 i; i < len; ++i) {
            SubStrategy memory strat = subStrategies[i];

            if (strat.isActive) sum += strat.strategy.totalAssets();
        }

        return sum;
    }

    // TODO: maybe a new function that returns structured data instead of encoded?
    function getPositionDetails() external view returns (bytes memory) {
        uint256 len = subStrategies.length;

        address[] memory strategies = new address[](len);
        uint16[] memory weights = new uint16[](len);
        bool[] memory actives = new bool[](len);

        for (uint256 i; i < len; ++i) {
            SubStrategy memory strat = subStrategies[i];
            strategies[i] = address(strat.strategy);
            weights[i] = strat.targetWeightBPS;
            actives[i] = strat.isActive;
        }

        return abi.encode(strategies, weights, actives);
    }

    function getSubStrategies() external view returns (SubStrategy[] memory) {
        return subStrategies;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _assertChildStrategyCompatible(address _strategy) internal view {
        require(_strategy.code.length != 0, SFStrategyAggregator__StrategyNotAContract());

        (bool ok, bytes memory returnData) = _strategy.staticcall(abi.encodeWithSignature("asset()"));
        require(ok && returnData.length >= 32, SFStrategyAggregator__InvalidStrategyAsset());

        address stratAsset = abi.decode(returnData, (address));
        require(stratAsset == address(underlying), SFStrategyAggregator__InvalidStrategyAsset());
    }

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
            require(subStrategyIndex[strat] != 0, SFStrategyAggregator__UnknownPerStrategyDataStrategy());

            for (uint256 j = i + 1; j < len; ++j) {
                require(strat != strategies_[j], SFStrategyAggregator__DuplicatePerStrategyDataStrategy());
            }
        }
    }

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

    /// @dev required by the OZ UUPS module.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.OPERATOR) {}
}
