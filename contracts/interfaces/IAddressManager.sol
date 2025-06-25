// SPDX-License-Identifier: GPL-3.0

import {ProtocolAddressType, ProposedRoleHolder, ProtocolAddress} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;

interface IAddressManager {
    function setRoleAcceptanceDelay(uint256 newDelay) external;
    function addProtocolAddress(
        string memory name,
        address addr,
        ProtocolAddressType addressType
    ) external;
    function deleteProtocolAddress(address addr) external;
    function updateProtocolAddress(string memory name, address newAddr) external;
    function createNewRole(bytes32 newRole) external returns (bool success);
    function removeRole(bytes32 roleToRemove) external returns (bool success);
    function proposeRoleHolder(bytes32 role, address proposedRoleHolder) external;
    function acceptProposedRole(bytes32 role) external returns (bool success);
    function revokeRoleHolder(bytes32 role, address account) external;
    function hasName(address addr, string memory name) external view returns (bool);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getProtocolAddressByName(
        string memory name
    ) external view returns (ProtocolAddress memory);
    function getProposedRoleHolder(
        bytes32 role
    ) external view returns (ProposedRoleHolder memory proposedHolder);
    function getRolesByAddress(address roleHolder) external view returns (bytes32[] memory roles);
    function isValidRole(bytes32 role) external view returns (bool);
    function getRoles() external view returns (bytes32[] memory roles);
}
