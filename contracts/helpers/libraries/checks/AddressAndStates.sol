//SPDX-License-Identifier: GPL-3.0

/**
 * @title AddressAndStates
 * @author Maikel Ordaz
 * @notice This contract will have simple checks for the addresses and module states
 */

import {ModuleState} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;

library AddressAndStates {
    error TakasureProtocol__ZeroAddress();
    error Module__WrongModuleState();

    function _notZeroAddress(address _address) internal pure {
        require(_address != address(0), TakasureProtocol__ZeroAddress());
    }

    function _onlyModuleState(ModuleState _currentState, ModuleState _neededState) internal view {
        require(_currentState == _neededState, Module__WrongModuleState());
    }
}
