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

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

pragma solidity 0.8.28;

contract ModuleManager is Ownable2Step, ReentrancyGuardTransient {
    enum Status {
        DISABLED,
        ENABLED,
        PAUSED,
        DEPRECATED
    }
    struct Module {
        address moduleAddress;
        Status moduleState;
    }

    mapping(address moduleAddr => Module) private addressToModule;

    error ModuleManager__AddressZeroNotAllowed();
    error ModuleManager__AlreadyModule();
    error ModuleManager__WrongInitialState();

    constructor() Ownable(msg.sender) {}

    /**
     * @notice A function to add a new module
     * @param newModule The new module address
     * @param status Can only be DISABLED or ENABLED
     */
    function addModule(address newModule, Status status) external onlyOwner nonReentrant {
        // New module can not be address 0, can not be already a module, and the status must be disabled or enabled
        require(newModule != address(0), ModuleManager__AddressZeroNotAllowed());
        require(
            addressToModule[newModule].moduleAddress == address(0),
            ModuleManager__AlreadyModule()
        );
        require(
            status == Status.DISABLED || status == Status.ENABLED,
            ModuleManager__WrongInitialState()
        );

        addressToModule[newModule].moduleAddress = newModule;
        addressToModule[newModule].moduleState = status;
    }
}
