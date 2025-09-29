// SPDX-License-Identifier: GPL-3.0

import {ProtocolAddress, ProtocolAddressType} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;

interface IAddressManager {
    function hasName(string memory name, address addr) external view returns (bool);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function hasType(ProtocolAddressType addressType, address addr) external view returns (bool);
    function getProtocolAddressByName(
        string memory name
    ) external view returns (ProtocolAddress memory protocolAddress);
}
