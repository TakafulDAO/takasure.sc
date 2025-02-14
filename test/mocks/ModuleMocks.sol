// SPDX-License-Identifier: GPL-3.0

import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";
import {ModuleState} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;

contract IsModule is TLDModuleImplementation {
    ModuleState private moduleState;

    /**
     * @notice Set the module state
     * @dev Only callable from the Module Manager
     */
    function setContractState(ModuleState newState) external override {
        moduleState = newState;
    }
}

contract IsNotModule {}
