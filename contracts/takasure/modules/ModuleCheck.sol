//SPDX-License-Identifier: GPL-3.0

/**
 * @title ModuleCheck
 * @author Maikel Ordaz
 * @notice This contract is intended to be inherited by every module in the Takasure protocol
 */

pragma solidity 0.8.28;

contract ModuleCheck {
    function isTLDModule() external pure returns (bytes4) {
        return bytes4(keccak256("isTLDModule()"));
    }
}
