//SPDX-License-Identifier: GPL-3.0

/**
 * @title TLDModuleImplementation
 * @author Maikel Ordaz
 * @notice This contract is intended to be inherited by every module in the Takasure protocol
 */
import {IAddressManager} from "contracts/interfaces/IAddressManager.sol";
import {IModuleManager} from "contracts/interfaces/IModuleManager.sol";

import {ModuleState, ProtocolAddressType} from "contracts/types/TakasureTypes.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";

pragma solidity 0.8.28;

abstract contract ModuleImplementation {
    IAddressManager internal addressManager;

    string public moduleName;

    modifier onlyContract(string memory name, address addressManagerAddress) {
        require(
            IAddressManager(addressManagerAddress).hasName(name, msg.sender),
            ModuleErrors.Module__NotAuthorizedCaller()
        );
        _;
    }

    modifier onlyRole(bytes32 role, address addressManagerAddress) {
        require(
            IAddressManager(addressManagerAddress).hasRole(role, msg.sender),
            ModuleErrors.Module__NotAuthorizedCaller()
        );
        _;
    }

    modifier onlyType(ProtocolAddressType addressType, address addressManagerAddress) {
        require(
            IAddressManager(addressManagerAddress).hasType(addressType, msg.sender),
            ModuleErrors.Module__NotAuthorizedCaller()
        );
        _;
    }

    function isValidModule() external pure returns (bytes4) {
        return bytes4(keccak256("isValidModule()"));
    }
}
