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

    IAddressManager public addressManager;

    EnumerableSet.AddressSet private subStrategySet;

    struct SubStrategyMeta {
        uint16 targetWeightBPS;
        bool isActive;
    }

    IERC20 private underlying;

    address public vault;

    uint256 public maxTVL;
    uint16 public totalTargetWeightBPS; // sum of all target weights in BPS

    mapping(address strategy => SubStrategyMeta) private subStrategyMeta;

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
    event OnStrategyLossReported(
        uint256 requestedAssets,
        uint256 withdrawnAssets,
        uint256 prevTotalAssets,
        uint256 newTotalAssets,
        uint256 shortfall
    );

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
        require(targetWeightBPS <= MAX_BPS, SFStrategyAggregator__InvalidTargetWeightBPS());
        require(subStrategySet.add(strategy), SFStrategyAggregator__SubStrategyAlreadyExists());

        subStrategyMeta[strategy] = SubStrategyMeta({targetWeightBPS: targetWeightBPS, isActive: true});

        _recomputeTotalTargetWeightBPS();
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
        require(subStrategySet.contains(strategy), SFStrategyAggregator__SubStrategyNotFound());
        require(targetWeightBPS <= MAX_BPS, SFStrategyAggregator__InvalidTargetWeightBPS());

        subStrategyMeta[strategy].targetWeightBPS = targetWeightBPS;
        subStrategyMeta[strategy].isActive = isActive;

        _recomputeTotalTargetWeightBPS();
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

        uint256 len = subStrategySet.length();

        // If there are no substrategies yet, return funds to vault
        if (len == 0) {
            underlying.safeTransfer(vault, assets);
            return 0;
        }

        (address[] memory dataStrategies, bytes[] memory perChildData) = _decodePerStrategyData(data);

        uint256 remaining = assets;

        for (uint256 i; i < len; ++i) {
            address stratAddr = subStrategySet.at(i);
            SubStrategyMeta memory meta = subStrategyMeta[stratAddr];

            if (!meta.isActive) continue;

            uint256 toAllocate = (assets * meta.targetWeightBPS) / MAX_BPS;
            if (toAllocate == 0) continue;
            if (toAllocate > remaining) toAllocate = remaining;

            underlying.forceApprove(stratAddr, toAllocate);

            bytes memory childData = _payloadFor(stratAddr, dataStrategies, perChildData);

            uint256 childInvested = ISFStrategy(stratAddr).deposit(toAllocate, childData);

            // If child did not pull all funds, reset approval
            if (underlying.allowance(address(this), stratAddr) != 0) {
                underlying.forceApprove(stratAddr, 0);
            }

            investedAssets += childInvested;
            remaining -= toAllocate;

            if (remaining == 0) break;
        }

        // Return any remainder to vault
        if (remaining > 0) underlying.safeTransfer(vault, remaining);

        return investedAssets;
    }

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
                              MAINTENANCE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Harvests rewards from all active child strategies.
     * @param data Additional data for harvesting (not used in this implementation).
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
     * @notice Rebalances all active child strategies.
     * @param data Additional data for rebalancing (not used in this implementation).
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
        uint256 sum = underlying.balanceOf(address(this));
        uint256 len = subStrategySet.length();

        for (uint256 i; i < len; ++i) {
            sum += ISFStrategy(subStrategySet.at(i)).totalAssets();
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
        uint256 sum = underlying.balanceOf(address(this));

        uint256 len = subStrategySet.length();
        for (uint256 i; i < len; ++i) {
            sum += ISFStrategy(subStrategySet.at(i)).maxWithdraw();
        }

        return sum;
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
        uint256 sum;
        uint256 len = subStrategySet.length();

        for (uint256 i; i < len; ++i) {
            sum += ISFStrategy(subStrategySet.at(i)).totalAssets();
        }

        return sum;
    }

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

    function getSubStrategies() external view returns (SubStrategy[] memory out) {
        uint256 len = subStrategySet.length();
        out = new SubStrategy[](len);

        for (uint256 i; i < len; ++i) {
            address s = subStrategySet.at(i);
            SubStrategyMeta memory m = subStrategyMeta[s];

            out[i] = SubStrategy({strategy: ISFStrategy(s), targetWeightBPS: m.targetWeightBPS, isActive: m.isActive});
        }
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
            require(subStrategySet.contains(strat), SFStrategyAggregator__UnknownPerStrategyDataStrategy());

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

    function _useIdleFunds(address receiver, uint256 remaining) internal returns (uint256 sent) {
        uint256 idle = underlying.balanceOf(address(this));
        if (idle == 0) return 0;

        sent = idle > remaining ? remaining : idle;
        underlying.safeTransfer(receiver, sent);
    }

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

    function _reportLoss(uint256 requestedAssets, uint256 withdrawnAssets, uint256 prevTotalAssets) internal {
        uint256 newTotalAssets = totalAssets();
        uint256 shortfall = requestedAssets - withdrawnAssets;

        emit OnStrategyLossReported(requestedAssets, withdrawnAssets, prevTotalAssets, newTotalAssets, shortfall);
    }

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

    /// @dev required by the OZ UUPS module.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.OPERATOR) {}
}
