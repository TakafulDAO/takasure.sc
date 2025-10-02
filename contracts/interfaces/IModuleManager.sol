// SPDX-License-Identifier: GPL-3.0

import {ModuleState} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;

interface IModuleManager {
    function addModule(address newModule) external;
    function changeModuleState(address module, ModuleState newState) external;
    function isActiveModule(address module) external view returns (bool);
    function getModuleState(address module) external view returns (ModuleState);
}
