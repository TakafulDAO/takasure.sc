//SPDX-License-Identifier: GPL-3.0

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

pragma solidity 0.8.28;

contract ModuleManager is Ownable2Step, ReentrancyGuardTransient {
    enum State {
        DISABLED,
        ENABLED,
        PAUSED,
        DEPRECATED
    }
    struct Module {
        address moduleAddress;
        State moduleState;
    }

    mapping(address moduleAddr => Module) private addressToModule;

    /*//////////////////////////////////////////////////////////////
                            EVENT AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnNewModule(address newModuleAddr, State newModuleStatus);
    event OnModuleStateChanged(State oldState, State newState);

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
    function addModule(address newModule, State state) external onlyOwner nonReentrant {
        // New module can not be address 0, can not be already a module, and the status must be disabled or enabled
        require(newModule != address(0), ModuleManager__AddressZeroNotAllowed());
        require(
            addressToModule[newModule].moduleAddress == address(0),
            ModuleManager__AlreadyModule()
        );
        require(
            state == State.DISABLED || state == State.ENABLED,
            ModuleManager__WrongInitialState()
        );

        addressToModule[newModule].moduleAddress = newModule;
        addressToModule[newModule].moduleState = state;

        emit OnNewModule(newModule, state);
    }

    /**
     * @notice A function to change the state of a module
     * @param module The module address to change the state
     * @param newState The new state of the module
     * @dev The module can not be DEPRECATED
     */
    function changeModuleStatus(address module, State newState) external onlyOwner {
        require(addressToModule[module].moduleAddress != address(0), ModuleManager__NotModule());
        require(module != address(0), ModuleManager__AddressZeroNotAllowed());
        require(
            addressToModule[module].moduleState != State.DEPRECATED,
            ModuleManager__WrongState()
        );

        State oldState = addressToModule[module].moduleState;
        addressToModule[module].moduleState = newState;

        emit OnModuleStateChanged(oldState, newState);
    }

    /*//////////////////////////////////////////////////////////////
                           GETTERS FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Return the module state
     * @param module The module address
     * @return The state of the module
     * @dev The given address must be a module
     */
    function getModuleState(address module) external view returns (State) {
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
