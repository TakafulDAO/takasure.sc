//SPDX-License-Identifier: GPL-3.0

/**
 * @title AddressAndStates
 * @author Maikel Ordaz
 * @notice This contract will have simple checks for the addresses and module states
 */

import {ModuleState} from "contracts/types/TakasureTypes.sol";
import {IAddressManager} from "contracts/interfaces/IAddressManager.sol";

pragma solidity 0.8.28;

library AddressAndStates {
    error TakasureProtocol__UnallowedAccess();
    error TakasureProtocol__ZeroAddress();
    error Module__WrongModuleState();

    function _checkRole(address addressManager, bytes32 role) internal view returns (bool) {
        return IAddressManager(addressManager).hasRole(role, msg.sender);
    }

    function _notZeroAddress(address _address) internal pure {
        require(_address != address(0), TakasureProtocol__ZeroAddress());
    }

    function _onlyModuleState(ModuleState _currentState, ModuleState _neededState) internal pure {
        require(_currentState == _neededState, Module__WrongModuleState());
    }
}
