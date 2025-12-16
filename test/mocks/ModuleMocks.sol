// SPDX-License-Identifier: GPL-3.0

import {ModuleImplementation} from "contracts/modules/moduleUtils/ModuleImplementation.sol";

pragma solidity 0.8.28;

contract IsModule is ModuleImplementation {
    // To avoid this contract to be count in coverage
    function test() external {}
}

contract IsNotModule {
    // To avoid this contract to be count in coverage
    function test() external {}
}
