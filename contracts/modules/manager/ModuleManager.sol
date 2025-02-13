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

import {IModuleCheck} from "contracts/interfaces/IModuleCheck.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {ModuleState} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;

contract ModuleManager is Ownable2Step, ReentrancyGuardTransient {
    struct Module {
        address moduleAddress;
        ModuleState moduleState;
    }

    mapping(address moduleAddr => Module) private addressToModule;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnNewModule(address newModuleAddr, ModuleState newModuleStatus);
    event OnModuleStateChanged(ModuleState oldState, ModuleState newState);

    error ModuleManager__AddressZeroNotAllowed();
    error ModuleManager__AlreadyModule();
    error ModuleManager__WrongInitialState();
    error ModuleManager__NotModule();
    error ModuleManager__WrongState();

    constructor() Ownable(msg.sender) {}

    /*//////////////////////////////////////////////////////////////
                      MODULE MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A function to add a new module
     * @param newModule The new module address
     * @param state Can only be DISABLED or ENABLED
     */
    function addModule(address newModule, ModuleState state) external onlyOwner nonReentrant {
        // New module can not be address 0, can not be already a module, and the status must be disabled or enabled
        require(newModule != address(0), ModuleManager__AddressZeroNotAllowed());
        require(
            addressToModule[newModule].moduleAddress == address(0),
            ModuleManager__AlreadyModule()
        );
        require(
            state == ModuleState.Disabled || state == ModuleState.Enabled,
            ModuleManager__WrongInitialState()
        );

        addressToModule[newModule].moduleAddress = newModule;
        addressToModule[newModule].moduleState = state;

        _checkIsModule(newModule);

        emit OnNewModule(newModule, state);
    }

    /**
     * @notice A function to change the state of a module
     * @param module The module address to change the state
     * @param newState The new state of the module
     * @dev The module can not be DEPRECATED
     */
    function changeModuleState(address module, ModuleState newState) external onlyOwner {
        require(addressToModule[module].moduleAddress != address(0), ModuleManager__NotModule());
        require(
            addressToModule[module].moduleState != ModuleState.Deprecated,
            ModuleManager__WrongState()
        );

        ModuleState oldState = addressToModule[module].moduleState;
        addressToModule[module].moduleState = newState;

        emit OnModuleStateChanged(oldState, newState);
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
        return addressToModule[module].moduleState == ModuleState.Enabled;
    }

    /**
     * @notice Return the module state
     * @param module The module address
     * @return The state of the module
     * @dev The given address must be a module
     */
    function getModuleState(address module) external view returns (ModuleState) {
        require(addressToModule[module].moduleAddress != address(0), ModuleManager__NotModule());
        return addressToModule[module].moduleState;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check if a given address is a module
     */
    function _checkIsModule(address _newModule) internal {
        try IModuleCheck(_newModule).isTLDModule() returns (bytes4 funcSelector) {
            if (funcSelector != IModuleCheck.isTLDModule.selector)
                revert ModuleManager__NotModule();
        } catch (bytes memory reason) {
            if (reason.length == 0) revert ModuleManager__NotModule();
        }
    }
}
