//SPDX-License-Identifier: GPL-3.0

import {ModuleState} from "contracts/types/States.sol";

pragma solidity 0.8.28;

interface IModuleImplementation {
    function setContractState(ModuleState newState) external;
    function isValidModule() external returns (bytes4);
}
