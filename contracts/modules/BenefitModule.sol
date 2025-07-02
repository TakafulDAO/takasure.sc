// SPDX-License-Identifier: GPL-3.0-only

import {IAddressManager} from "contracts/interfaces/IAddressManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";

import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ModuleState} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;

contract BenefitModule is Initializable, UUPSUpgradeable, TLDModuleImplementation {
    IAddressManager private addressManager;
    ModuleState private moduleState;

    string public moduleName;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _addressManager, string calldata _moduleName) external initializer {
        __UUPSUpgradeable_init();

        addressManager = IAddressManager(_addressManager);
        moduleName = _moduleName;
    }

    /**
     * @notice Set the module state
     * @dev Only callable from the Module Manager
     */
    function setContractState(
        ModuleState newState
    ) external override onlyContract("MODULE_MANAGER", address(addressManager)) {
        moduleState = newState;
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(Roles.OPERATOR, address(addressManager)) {}
}
