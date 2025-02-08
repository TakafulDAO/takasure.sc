//SPDX-License-Identifier: GPL-3.0

/**
 * @title AddressCheck
 * @author Maikel Ordaz
 * @notice This contract will have simple checks for the addresses
 */

pragma solidity 0.8.28;

library AddressCheck {
    error TakasureProtocol__ZeroAddress();

    function _notZeroAddress(address _address) internal pure {
        require(_address != address(0), TakasureProtocol__ZeroAddress());
    }
}
