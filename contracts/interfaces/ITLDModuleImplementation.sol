//SPDX-License-Identifier: GPL-3.0

import {ModuleState} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;

interface ITLDModuleImplementation {
    function setContractState(ModuleState newState) external;
    function isTLDModule() external returns (bytes4);
    function moduleName() external returns (string memory);
}
