// SPDX-License-Identifier: GPL-3.0

import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";
import {ModuleState} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;

contract IsModule is TLDModuleImplementation {
    // To avoid this contract to be count in coverage
    function test() external {}
}

contract IsNotModule {
    // To avoid this contract to be count in coverage
    function test() external {}
}
