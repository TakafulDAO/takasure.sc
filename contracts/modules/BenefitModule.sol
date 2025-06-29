// SPDX-License-Identifier: GPL-3.0-only

import {IAddressManager} from "contracts/interfaces/IAddressManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";

import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ModuleState} from "contracts/types/TakasureTypes.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";

pragma solidity 0.8.28;

contract BenefitModule is Initializable, UUPSUpgradeable, TLDModuleImplementation {
    IAddressManager private addressManager;
    ModuleState private moduleState;

    modifier onlyContract(string memory name) {
        require(
            AddressAndStates._checkName(address(addressManager), name),
            ModuleErrors.Module__NotAuthorizedCaller()
        );
        _;
    }

    modifier onlyRole(bytes32 role) {
        require(
            AddressAndStates._checkRole(address(addressManager), role),
            ModuleErrors.Module__NotAuthorizedCaller()
        );
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _addressManager) external initializer {
        __UUPSUpgradeable_init();

        addressManager = IAddressManager(_addressManager);
    }

    /**
     * @notice Set the module state
     * @dev Only callable from the Module Manager
     */
    function setContractState(
        ModuleState newState
    ) external override onlyContract("MODULE_MANAGER") {
        moduleState = newState;
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(Roles.OPERATOR) {}
}
