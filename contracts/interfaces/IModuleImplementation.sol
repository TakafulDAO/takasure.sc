//SPDX-License-Identifier: GPL-3.0

import {ModuleState} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;

interface IModuleImplementation {
    function setContractState(ModuleState newState) external;
<<<<<<<< HEAD:contracts/interfaces/modules/ITLDModuleImplementation.sol
    function isTLDModule() external returns (bytes4);
    function moduleName() external returns (string memory);
========
    function isValidModule() external returns (bytes4);
>>>>>>>> main:contracts/interfaces/IModuleImplementation.sol
}
