//SPDX-License-Identifier: GPL-3.0

/**
 * @title ModuleManager
 * @author Maikel Ordaz
 * @notice This contract will manage the modules of the Takasure protocol
 * @dev The logic in this contract will have three main purposes:
 *      1. Add/Remove new modules to the protocol
 *      2. Pause/Unpause or Deprecate modules in the protocol
 *      3. Comunicate with the core protocol contracts if the module is paused or not
 * @dev The state in this contract will be mainly the modules addresses and their status and any other auxiliary data
 */

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

pragma solidity 0.8.28;

contract ModuleManager is Ownable2Step {
    enum Status {
        ACTIVE,
        PAUSED,
        DEPRECATED
    }
    struct Module {
        address moduleAddress;
        Status moduleState;
    }

    mapping(address moduleAddr => Module) private addressToModule;

    constructor() Ownable(msg.sender) {}
}
