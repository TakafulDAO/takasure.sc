// SPDX-License-Identifier: GPL-3.0

import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";

pragma solidity 0.8.28;

contract IsModule is TLDModuleImplementation {
    ///@dev required by the Protocol to build this contract as module
    function _isTLDModule() internal override {}
}

contract IsNotModule {}
