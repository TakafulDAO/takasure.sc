// SPDX-License-Identifier: GPL-3.0

/**
 * @title ModuleManager
 * @author Maikel Ordaz
 * @notice This contract will manage the modules of the Takasure protocol
 * @dev The logic in this contract will have three main purposes:
 *      1. Add/Remove new modules to the protocol
 *      2. Disable/Enable, Pause/Unpause or Deprecate modules in the protocol
 *      3. Comunicate with the core protocol contracts if the module is paused or not
 * @dev The state in this contract will be mainly the modules addresses and their status and any other auxiliary data
 */

import {ITLDModuleImplementation} from "contracts/interfaces/ITLDModuleImplementation.sol";
import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable, OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {ModuleState} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;

contract ModuleManager is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardTransientUpgradeable
{
    address private addressManager;

    mapping(address moduleAddr => ModuleState) private addressToModuleState;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnNewModule(address newModuleAddr);
    event OnModuleStateChanged(
        address indexed moduleAddress,
        ModuleState oldState,
        ModuleState newState
    );

    error ModuleManager__InvalidCaller();
    error ModuleManager__AddressZeroNotAllowed();
    error ModuleManager__AlreadyModule();
    error ModuleManager__NotModule();
    error ModuleManager__WrongState();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _addressManager) external initializer {
        __UUPSUpgradeable_init();
        __Ownable2Step_init();
        __Ownable_init(msg.sender);
        __ReentrancyGuardTransient_init();
        addressManager = _addressManager;
    }

    /*//////////////////////////////////////////////////////////////
                      MODULE MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A function to add a new module
     * @param newModule The new module address
     */
    function addModule(address newModule) external nonReentrant {
        require(msg.sender == addressManager, ModuleManager__InvalidCaller());
        // New module can not be address 0, can not be already a module, and the status will be enabled
        require(newModule != address(0), ModuleManager__AddressZeroNotAllowed());
        require(
            addressToModuleState[newModule] == ModuleState.Unset,
            ModuleManager__AlreadyModule()
        );

        addressToModuleState[newModule] = ModuleState.Enabled;

        _checkIsModule(newModule);
        ITLDModuleImplementation(newModule).setContractState(ModuleState.Enabled);

        emit OnNewModule(newModule);
    }

    /**
     * @notice A function to change the state of a module
     * @param module The module address to change the state
     * @param newState The new state of the module
     * @dev The module can not be DEPRECATED
     */
    function changeModuleState(address module, ModuleState newState) external onlyOwner {
        require(
            addressToModuleState[module] != ModuleState.Unset &&
                addressToModuleState[module] != ModuleState.Deprecated,
            ModuleManager__WrongState()
        );

        ModuleState oldState = addressToModuleState[module];
        addressToModuleState[module] = newState;

        ITLDModuleImplementation(module).setContractState(newState);

        emit OnModuleStateChanged(module, oldState, newState);
    }

    /*//////////////////////////////////////////////////////////////
                           GETTERS FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Function that will be used by Core contracts to confirm if an address is a module
     * @param module The module address
     * @return True if the address is a module, false otherwise
     */
    function isActiveModule(address module) external view returns (bool) {
        return addressToModuleState[module] == ModuleState.Enabled;
    }

    /**
     * @notice Return the module state
     * @param module The module address
     * @return The state of the module
     * @dev The given address must be a module
     */
    function getModuleState(address module) external view returns (ModuleState) {
        return addressToModuleState[module];
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check if a given address is a module
     */
    function _checkIsModule(address _newModule) internal {
        try ITLDModuleImplementation(_newModule).isTLDModule() returns (bytes4 funcSelector) {
            if (funcSelector != ITLDModuleImplementation.isTLDModule.selector)
                revert ModuleManager__NotModule();
        } catch (bytes memory) {
            revert ModuleManager__NotModule();
        }
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
