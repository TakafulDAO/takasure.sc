//SPDX-License-Identifier: GPL-3.0

/**
 * @title TLDModuleImplementation
 * @author Maikel Ordaz
 * @notice This contract is intended to be inherited by every module in the Takasure protocol
 */
import {ModuleState} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;

abstract contract TLDModuleImplementation {
    function setContractState(ModuleState newState) external virtual;

    function isTLDModule() external pure returns (bytes4) {
        return bytes4(keccak256("isTLDModule()"));
    }
}
