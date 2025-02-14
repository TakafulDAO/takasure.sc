//SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

interface ITLDModuleImplementation {
    function isTLDModule() external returns (bytes4);
}
