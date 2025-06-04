// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

interface IAddressManager {
    function createNewRole(bytes32 newRole) external returns (bool success);
    function removeRole(bytes32 roleToRemove) external returns (bool success);
    function proposeRoleHolder(bytes32 role, address proposedRoleHolder) external;
    function acceptProposedRole(bytes32 role) external returns (bool success);
    function isValidRole(bytes32 role) external view returns (bool);
    function getRoles() external view returns (bytes32[] memory roles);
    function hasRole(bytes32 role, address account) external view returns (bool);
}
