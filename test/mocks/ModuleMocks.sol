// SPDX-License-Identifier: GPL-3.0

import {ModuleCheck} from "contracts/modules/moduleUtils/ModuleCheck.sol";

pragma solidity 0.8.28;

contract IsModule is ModuleCheck {
    ///@dev required by the Protocol to build this contract as module
    function _isTLDModule() internal override {}
}

contract IsNotModule {}
