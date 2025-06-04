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

    uint256 private roleAcceptanceDelay; // Maximum time allowed to accept a proposed role

    struct ProposedHolder {
        address proposedHolder;
        uint256 proposalTime;
    }

    mapping(bytes32 role => address roleHolder) public roleHolders;
    mapping(bytes32 role => ProposedHolder proposedHolder) public proposedRoleHolders;

    EnumerableSet.Bytes32Set private _roles;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnRoleCreated(bytes32 indexed role);
    event OnRoleRemoved(bytes32 indexed role);
    event OnProposedRoleHolder(bytes32 indexed role, address indexed proposedHolder);
    event OnNewRoleHolder(bytes32 indexed role, address indexed newHolder);

    error AddressManager__RoleAlreadyExists();
    error AddressManager__RoleDoesNotExist();
    error AddressManager__AlreadyRoleHolder();
    error AddressManager__InvalidCaller();
    error AddressManager__NoProposedHolder();
    error AddressManager__TooLateToAccept();
    error AddressManager__NotRoleHolder();

    constructor() Ownable(msg.sender) {
        roleAcceptanceDelay = 1 days;
    }

    /*//////////////////////////////////////////////////////////////
                             ROLE CREATION
    //////////////////////////////////////////////////////////////*/

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
     * @param roleToRemove The role to be removed
     * @dev This function can only be called by the owner of the contract.
     * @return success A boolean indicating whether the role was successfully removed
     */
    function removeRole(bytes32 roleToRemove) external onlyOwner returns (bool success) {
        require(_roles.contains(roleToRemove), AddressManager__RoleDoesNotExist());
        success = _roles.remove(roleToRemove);

        emit OnRoleRemoved(roleToRemove);
    }

    /*//////////////////////////////////////////////////////////////
                              ASSIGN ROLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Propose a role to an address.
     * @param role The role to be granted.
     * @param proposedRoleHolder The address to which the role will be granted.
     * @dev This function can only be called by the owner of the contract.
     * @dev The role must already exist in the AddressManager.
     * @dev To remove a proposal just create a new proposal with the same role, can be to address(0).
     */
    function proposeRoleHolder(bytes32 role, address proposedRoleHolder) external onlyOwner {
        require(_roles.contains(role), AddressManager__RoleDoesNotExist());

        // Check if the role is already assigned to the proposed holder
        if (roleHolders[role] != proposedRoleHolder) revert AddressManager__AlreadyRoleHolder();

        ProposedHolder memory proposedHolder = ProposedHolder({
            proposedHolder: proposedRoleHolder,
            proposalTime: block.timestamp
        });

        // Assign the proposed holder with a delay
        proposedRoleHolders[role] = proposedHolder;

        emit OnProposedRoleHolder(role, proposedRoleHolder);
    }

    /**
     * @notice Accepts a proposed role after the acceptance delay.
     * @param role The role to be accepted.
     * @dev This function can only be called by the proposed holder of the role.
     */
    function acceptProposedRole(bytes32 role) external returns (bool success) {
        require(_roles.contains(role), AddressManager__RoleDoesNotExist());

        ProposedHolder memory proposedHolder = proposedRoleHolders[role];

        // There must be a proposed holder for the role, and the caller must be the proposed holder
        require(proposedHolder.proposedHolder != address(0), AddressManager__NoProposedHolder());
        require(proposedHolder.proposedHolder == msg.sender, AddressManager__InvalidCaller());

        // Check if the proposal time has passed
        require(
            block.timestamp <= proposedHolder.proposalTime + roleAcceptanceDelay,
            AddressManager__TooLateToAccept()
        );

        address currentHolder = roleHolders[role];
        if (currentHolder != address(0)) _revokeRole(role, currentHolder);

        // Assign the role to the proposed holder
        success = _grantRole(role, msg.sender);

        // Clear the proposed holder
        delete proposedRoleHolders[role];

        emit OnNewRoleHolder(role, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                              REVOKE ROLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Revokes a role from an address.
     * @param role The role to be revoked.
     * @param account The address from which the role will be revoked.
     * @dev This function can only be called by the owner of the contract.
     */
    function revokeRoleHolder(bytes32 role, address account) external onlyOwner {
        require(_roles.contains(role), AddressManager__RoleDoesNotExist());
        require(roleHolders[role] == account, AddressManager__NotRoleHolder());

        _revokeRole(role, account);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Checks if a role exists in the AddressManager
     * @param role The role to check for existence
     * @return bool A boolean indicating whether the role exists
     */
    function isValidRole(bytes32 role) external view returns (bool) {
        return _roles.contains(role);
    }

    /**
     * @notice Returns the list of roles in the AddressManager
     * @return roles An array of bytes32 representing the roles
     */
    function getRoles() external view returns (bytes32[] memory roles) {
        roles = new bytes32[](_roles.length());
        for (uint256 i = 0; i < _roles.length(); i++) {
            roles[i] = _roles.at(i);
        }
    }

    function hasRole(bytes32 role, address account) public view override returns (bool) {
        require(_roles.contains(role), AddressManager__RoleDoesNotExist());

        return super.hasRole(role, account);
    }
}
