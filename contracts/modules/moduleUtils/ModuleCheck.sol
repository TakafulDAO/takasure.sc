//SPDX-License-Identifier: GPL-3.0

/**
 * @title ModuleCheck
 * @author Maikel Ordaz
 * @notice This contract is intended to be inherited by every module in the Takasure protocol
 */

pragma solidity 0.8.28;

abstract contract ModuleCheck {
    function isTLDModule() external returns (bytes4) {
        _isTLDModule();
        return bytes4(keccak256("isTLDModule()"));
    }

    function _isTLDModule() internal virtual;
}
