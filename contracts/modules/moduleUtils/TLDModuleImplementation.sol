//SPDX-License-Identifier: GPL-3.0

/**
 * @title TLDModuleImplementation
 * @author Maikel Ordaz
 * @notice This contract is intended to be inherited by every module in the Takasure protocol
 */
import {ModuleState} from "contracts/types/TakasureTypes.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";

pragma solidity 0.8.28;

abstract contract TLDModuleImplementation {
    modifier onlyContract(string memory name, address addressManager) {
        require(
            AddressAndStates._checkName(addressManager, name),
            ModuleErrors.Module__NotAuthorizedCaller()
        );
        _;
    }

    modifier onlyRole(bytes32 role, address addressManager) {
        require(
            AddressAndStates._checkRole(addressManager, role),
            ModuleErrors.Module__NotAuthorizedCaller()
        );
        _;
    }

    function setContractState(ModuleState newState) external virtual;

    function isTLDModule() external pure returns (bytes4) {
        return bytes4(keccak256("isTLDModule()"));
    }
}
