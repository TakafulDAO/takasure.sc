//SPDX-License-Identifier: GPL-3.0

/**
 * @title RevShareModule
 * @author Maikel Ordaz
 * @dev Allow NFT holders to receive a share of the revenue generated by the platform
 * @dev Important notes:
 *      1. It will mint a new NFT to all users that deposit maximum contribution
 *      2. It will mint a new NFT per each 250USDC expends by a coupon buyer
 * @dev Upgradeable contract with UUPS pattern
 */
import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";

import {ModuleState} from "contracts/types/TakasureTypes.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";

pragma solidity 0.8.28;

contract RevShareModule is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    TLDModuleImplementation
{
    ModuleState private moduleState;

    /// @custom:oz-upgrades-unsafe-allow-constructor
    constructor() {
        disableInitializers();
    }

    function initialize(address _operator, address _moduleManager) external initializer {
        AddressAndStates._notZeroAddress(_operator);
        AddressAndStates._notZeroAddress(_moduleManager);

        __UUPSUpgradeable_init();
        __AccessControl_init();

        _grantRole(ModuleConstants.TAKADAO_OPERATOR, _operator);
        _grantRole(ModuleConstants.MODULE_MANAGER, _moduleManager);
    }

    /**
     * @notice Set the module state
     *  @dev Only callble from the Module Manager
     */
    function setContractState(
        ModuleState newState
    ) external override onlyRole(ModuleConstants.MODULE_MANAGER) {
        moduleState = newState;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(ModuleConstants.TAKADAO_OPERATOR) {}
}
