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
import {StrategyConfig} from "contracts/types/TakasureTypes.sol";
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

    struct SubStrategy {
        ISFStrategy strategy;
        uint16 targetWeightBPS; // 0 to 10000 (0% to 100%)
        bool isActive;
    }

    SubStrategy[] private subStrategies;

    address public vault;

    uint256 public maxTVL;

    mapping(address strat => uint256) private subStrategyIndex; // strategy => index + 1

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint16 private constant MAX_BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnMaxTVLUpdated(uint256 oldMaxTVL, uint256 newMaxTVL);
    event OnSubStrategyAdded(address indexed strategy, uint16 targetWeightBps, bool isActive);
    event OnSubStrategyUpdated(address indexed strategy, uint16 targetWeightBps, bool isActive);
    event OnStrategyLossReported(uint256 prevAssets, uint256 newAssets, uint256 lossAmount);

    error SFStrategyAggregator__NotAuthorizedCaller();
    error SFStrategyAggregator__InvalidTargetWeightBps();
    error SFStrategyAggregator__SubStrategyAlreadyExists();
    error SFStrategyAggregator__SubStrategyNotFound();
    error SFStrategyAggregator__NotZeroAmount();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyRole(bytes32 role, address addressManagerAddress) {
        require(
            IAddressManager(addressManagerAddress).hasRole(role, msg.sender),
            SFStrategyAggregator__NotAuthorizedCaller()
        );
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

    modifier onlyContract(string memory name, address addressManagerAddress) {
        require(
            IAddressManager(addressManagerAddress).hasName(name, msg.sender),
            SFStrategyAggregator__NotAuthorizedCaller()
        );
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

    function pause() external onlyRole(Roles.PAUSE_GUARDIAN, address(addressManager)) {
        _pause();
    }

    function unpause() external onlyRole(Roles.PAUSE_GUARDIAN, address(addressManager)) {
        _unpause();
    }

    function setMaxTVL(uint256 newMaxTVL) external onlyRole(Roles.OPERATOR, address(addressManager)) {
        uint256 oldMaxTVL = maxTVL;
        maxTVL = newMaxTVL;
        emit OnMaxTVLUpdated(oldMaxTVL, newMaxTVL);
    }

    function setConfig(
        bytes calldata /*newConfig*/
    )
        external
        onlyRole(Roles.OPERATOR, address(addressManager))
    {
        // todo: check if needed. Decode array of strategy, weights, and active status.
    }

    /*//////////////////////////////////////////////////////////////
                           SUB-STRATEGY MGMT
    //////////////////////////////////////////////////////////////*/

    function addSubStrategy(address strategy, uint16 targetWeightBPS, bool isActive)
        external
        onlyRole(Roles.OPERATOR, address(addressManager))
    {
        require(targetWeightBPS <= MAX_BPS, SFStrategyAggregator__InvalidTargetWeightBps());
        require(subStrategyIndex[strategy] == 0, SFStrategyAggregator__SubStrategyAlreadyExists());

        subStrategies.push(
            SubStrategy({strategy: ISFStrategy(strategy), targetWeightBPS: targetWeightBPS, isActive: isActive})
        );
        subStrategyIndex[strategy] = subStrategies.length;

        emit OnSubStrategyAdded(strategy, targetWeightBPS, isActive);
    }

    function updateSubStrategy(address strategy, uint16 targetWeightBPS, bool isActive)
        external
        onlyRole(Roles.OPERATOR, address(addressManager))
    {
        require(subStrategyIndex[strategy] != 0, SFStrategyAggregator__SubStrategyNotFound());

        uint256 index = subStrategyIndex[strategy] - 1;

        SubStrategy storage strat = subStrategies[index];
        strat.targetWeightBPS = targetWeightBPS;
        strat.isActive = isActive;

        emit OnSubStrategyUpdated(strategy, targetWeightBPS, isActive);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets, bytes calldata data)
        external
        onlyContract("PROTOCOL__SF_VAULT", address(addressManager))
        whenNotPaused
        returns (uint256 investedAssets)
    {
        require(assets > 0, SFStrategyAggregator__NotZeroAmount());

        uint256 len = subStrategies.length;

        // No substrategies yet, return assets.
        if (len == 0) return assets;

        // todo: interpret data
        uint256 remaining = assets;

        for (uint256 i; i < len; ++i) {
            SubStrategy memory strat = subStrategies[i];

            if (strat.isActive) {
                uint256 toAllocate = (assets * strat.targetWeightBPS) / MAX_BPS;

                if (toAllocate == 0) continue;
                if (toAllocate > remaining) toAllocate = remaining;

                // Forward funds to child strategy
                underlying.forceApprove(address(strat.strategy), toAllocate);
                uint256 childInvested = strat.strategy.deposit(toAllocate, bytes(""));

                investedAssets += childInvested;
                remaining -= toAllocate;

                if (remaining == 0) break;
            }
        }

        // Any leftovers stay as idle balance in the aggregator.
        // totalAssets() counts both idle + children.
        return investedAssets + remaining;
    }

    function withdraw(uint256 assets, address receiver, bytes calldata data)
        external
        onlyContract("PROTOCOL__SF_VAULT", address(addressManager))
        whenNotPaused
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
            uint256 prevAssets = assets; // todo: maybe snapshot before withdraw? check
            uint256 newAssets = totalAssets();
            uint256 lossAmount = assets - withdrawnAssets;
            emit OnStrategyLossReported(prevAssets, newAssets, lossAmount);
        }

        return withdrawnAssets;
    }

    /*//////////////////////////////////////////////////////////////
                               EMERGENCY
    //////////////////////////////////////////////////////////////*/

    function emergencyExit(address receiver) external onlyRole(Roles.OPERATOR, address(addressManager)) {
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

    function harvest(bytes calldata data) external onlyKeeperOrOperator {
        // todo: include in data the children to harvest?
        uint256 len = subStrategies.length;

        for (uint256 i; i < len; ++i) {
            SubStrategy memory strat = subStrategies[i];

            if (strat.isActive) ISFStrategyMaintenance(address(strat.strategy)).harvest(bytes(""));
        }
    }

    function rebalance(bytes calldata data) external onlyKeeperOrOperator {
        // todo: finish this function
        uint256 len = subStrategies.length;

        for (uint256 i; i < len; ++i) {
            SubStrategy memory strat = subStrategies[i];

            if (strat.isActive) ISFStrategyMaintenance(address(strat.strategy)).rebalance(data);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function asset() external view returns (address) {
        return address(underlying);
    }

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

    function maxDeposit() external view returns (uint256) {
        // 0 means no cap
        if (maxTVL == 0) return type(uint256).max;

        uint256 current = totalAssets();
        if (current >= maxTVL) return 0;
        return maxTVL - current;
    }

    function maxWithdraw() external view returns (uint256) {
        // todo: check
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

    ///@dev required by the OZ UUPS module.
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(Roles.OPERATOR, address(addressManager))
    {}
}
