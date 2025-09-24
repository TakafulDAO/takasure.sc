//SPDX-License-Identifier: GPL-3.0

/**
 * @title AddressAndStates
 * @author Maikel Ordaz
 * @notice This contract will have simple checks for the addresses and module states
 */

import {ModuleState, ProtocolAddressType} from "contracts/types/TakasureTypes.sol";
import {IAddressManager} from "contracts/interfaces/IAddressManager.sol";
import {IModuleManager} from "contracts/interfaces/IModuleManager.sol";

pragma solidity 0.8.28;

library AddressAndStates {
    error TakasureProtocol__UnallowedAccess();
    error TakasureProtocol__ZeroAddress();
    error Module__WrongModuleState();

    function _checkName(string memory name, address addressManager) internal view returns (bool) {
        return IAddressManager(addressManager).hasName(name, msg.sender);
    }

    function _checkRole(bytes32 role, address addressManager) internal view returns (bool) {
        return IAddressManager(addressManager).hasRole(role, msg.sender);
    }

    function _checkType(
        ProtocolAddressType addressType,
        address addressManager
    ) internal view returns (bool) {
        return IAddressManager(addressManager).hasType(addressType, msg.sender);
    }

    function _notZeroAddress(address _address) internal pure {
        require(_address != address(0), TakasureProtocol__ZeroAddress());
    }

    function _onlyModuleState(
        ModuleState _neededState,
        address moduleAddress,
        address moduleManager
    ) internal view {
        require(
            IModuleManager(moduleManager).getModuleState(moduleAddress) == _neededState,
            Module__WrongModuleState()
        );
    }
}
