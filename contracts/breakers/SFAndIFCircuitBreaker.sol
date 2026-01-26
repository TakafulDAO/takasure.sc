// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFAndIFCircuitBreaker
 * @author Maikel Ordaz
 * @notice Circuit Breaker contract for Save Funds and Investment Fund modules
 * @dev Upgradeable contract with UUPS pattern
 */

import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ISFVault} from "contracts/interfaces/saveFunds/ISFVault.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

pragma solidity 0.8.28;

contract SFAndIFCircuitBreaker is Initializable, UUPSUpgradeable, ReentrancyGuardTransientUpgradeable {
    IAddressManager private addressManager;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    error SFAndIFCircuitBreaker__NotAuthorizedCaller();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyRole(bytes32 role) {
        require(addressManager.hasRole(role, msg.sender), SFAndIFCircuitBreaker__NotAuthorizedCaller());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IAddressManager _addressManager) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();

        addressManager = _addressManager;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev required by the OZ UUPS module.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.OPERATOR) {}
}
