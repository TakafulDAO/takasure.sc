// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFStrategyAggregator
 * @author Maikel Ordaz
 * @notice Multi strategy aggregator for SaveFunds vaults.
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract SFStrategyAggregator is
    ISFStrategy,
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
        uint16 targetWeightBps; // 0 to 10000 (0% to 100%)
        bool isActive;
    }

    SubStrategy[] private subStrategies;

    uint256 public maxTVL;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IAddressManager _addressManager, IERC20 _asset, uint256 _maxTVL) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        __Pausable_init();

        addressManager = _addressManager;

        underlying = _asset;
        maxTVL = _maxTVL;
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    // todo: access control
    function pause() external {
        _pause();
    }

    // todo: access control
    function unpause() external {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function asset() external view returns (address) {
        return address(underlying);
    }

    function totalAssets() public view override returns (uint256) {
        uint256 sum = underlying.balanceOf(address(this)); // iddle inside aggregator

        uint256 len = subStrategies.length;

        for (uint256 i; i < len; ++i) {
            SubStrategy memory strat = subStrategies[i];

            if (!strat.isActive) continue;

            sum += strat.strategy.totalAssets();
        }

        return sum;
    }

    function maxDeposit() external view override returns (uint256) {
        // 0 means no cap
        if (maxTVL == 0) return type(uint256).max;

        uint256 current = totalAssets();
        if (current >= maxTVL) return 0;
        return maxTVL - current;
    }

    function maxWithdraw() external view override returns (uint256) {
        // todo: check
        return totalAssets();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    ///@dev required by the OZ UUPS module.
    // todo: access control
    function _authorizeUpgrade(address newImplementation) internal override {}

    // todo: implement the next functions, written here for now for compilation issues as I'm inheriting ISFStrategy
    function withdraw(uint256, address, bytes calldata) external returns (uint256) {}
    function vault() external view returns (address) {}
    function setMaxTVL(uint256) external {}
    function setKeeper(address) external {}
    function setConfig(bytes calldata) external {}
    function emergencyExit(address) external {}
    function deposit(uint256, bytes calldata) external returns (uint256) {}
}
