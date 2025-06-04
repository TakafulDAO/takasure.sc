// SPDX-License-Identifier: GPL-3.0

/**
 * @title AddressManager
 * @author Maikel Ordaz
 * @notice This contract will manage the addresses in the TLD protocol of the Takasure protocol
 */

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

pragma solidity 0.8.28;

contract AddressManager is Ownable2Step, AccessControl {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    EnumerableSet.Bytes32Set private _roles;

    event OnRoleCreated(bytes32 indexed role);
    event OnRoleRemoved(bytes32 indexed role);

    error AddressManager__RoleAlreadyExists();
    error AddressManager__RoleDoesNotExist();

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Creates a new role in the AddressManager
     * @param newRole The new role to be created
     * @dev This function can only be called by the owner of the contract.
     * @return success A boolean indicating whether the role was successfully created
     */
    function createNewRole(bytes32 newRole) external onlyOwner returns (bool success) {
        require(!_roles.contains(newRole), AddressManager__RoleAlreadyExists());
        success = _roles.add(newRole);

        emit OnRoleCreated(newRole);
    }

    /**
     * @notice Removes an existing role from the AddressManager
     * @param role The role to be removed
     * @dev This function can only be called by the owner of the contract.
     * @return success A boolean indicating whether the role was successfully removed
     */
    function removeRole(bytes32 roleToRemove) external onlyOwner returns (bool success) {
        require(_roles.contains(roleToRemove), AddressManager__RoleDoesNotExist());
        success = _roles.remove(roleToRemove);

        emit OnRoleRemoved(roleToRemove);
    }

    /**
     * @notice Checks if a role exists in the AddressManager
     * @param role The role to check for existence
     * @return bool A boolean indicating whether the role exists
     */
    function isValidRole(bytes32 role) external view returns (bool) {
        return _roles.contains(role);
    }
}
