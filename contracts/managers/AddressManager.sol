// SPDX-License-Identifier: GPL-3.0

/**
 * @title AddressManager
 * @author Maikel Ordaz
 * @notice This contract will manage the addresses in the TLD protocol of the Takasure protocol
 */

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {ProtocolAddressType, ProtocolAddress, ProposedRoleHolder} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;

contract AddressManager is Ownable2Step, AccessControl {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 private roleAcceptanceDelay; // Maximum time allowed to accept a proposed role

    // Related to the protocol addresses
    mapping(address protocolAddress => bytes32 nameHash) public protocolAddressesNames;
    mapping(bytes32 nameHash => ProtocolAddress) private protocolAddressesByName;

    // Related to the roles
    mapping(address roleHolder => bytes32[] role) private rolesByAddress;
    mapping(bytes32 role => address roleHolder) public currentRoleHolders;
    mapping(bytes32 role => ProposedRoleHolder proposedRoleHolder) private proposedRoleHolders;

    EnumerableSet.Bytes32Set private _protocolRoles;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnNewProtocolAddress(
        string indexed name,
        address indexed addr,
        ProtocolAddressType addressType
    );
    event OnProtocolAddressDeleted(address indexed addr, ProtocolAddressType addressType);
    event OnProtocolAddressUpdated(string indexed name, address indexed newAddr);
    event OnRoleCreated(bytes32 indexed role);
    event OnRoleRemoved(bytes32 indexed role);
    event OnProposedRoleHolder(bytes32 indexed role, address indexed proposedHolder);
    event OnNewRoleHolder(bytes32 indexed role, address indexed newHolder);

    error AddressManager__InvalidNameLength();
    error AddressManager__AddressZero();
    error AddressManager__AddressAlreadyExists();
    error AddressManager__AddressDoesNotExist();
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
                               ADDRESSES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds a new address to the AddressManager
     * @param name The name of the address to be added
     * @param addr The address to be added
     * @param addressType The type of the address (ADMIN, MODULE, PROTOCOL)
     * @dev This function can only be called by the owner of the contract.
     */
    function addProtocolAddress(
        string memory name,
        address addr,
        ProtocolAddressType addressType
    ) external onlyOwner {
        require(
            bytes(name).length > 0 && bytes(name).length <= 32,
            AddressManager__InvalidNameLength()
        );
        require(addr != address(0), AddressManager__AddressZero());

        bytes32 nameHash = keccak256(abi.encode(name));
        require(
            protocolAddressesByName[nameHash].addr == address(0),
            AddressManager__AddressAlreadyExists()
        );

        ProtocolAddress memory newProtocolAddress = ProtocolAddress({
            name: nameHash,
            addr: addr,
            addressType: addressType
        });

        // protocolAddresses[addr] = newProtocolAddress;
        protocolAddressesByName[nameHash] = newProtocolAddress;
        protocolAddressesNames[addr] = nameHash;

        emit OnNewProtocolAddress(name, addr, addressType);
    }

    /**
     * @notice Deletes an address from the AddressManager
     * @param addr The address to be deleted
     * @dev This function can only be called by the owner of the contract.
     * @dev This function will also remove the address from the rolesByAddress mapping.
     */
    function deleteProtocolAddress(address addr) external onlyOwner {
        require(addr != address(0), AddressManager__AddressZero());

        bytes32 nameHash = protocolAddressesNames[addr];
        ProtocolAddress memory protocolAddress = protocolAddressesByName[nameHash];

        require(protocolAddress.addr != address(0), AddressManager__AddressDoesNotExist());

        ProtocolAddressType addressType = protocolAddress.addressType;

        // Remove the address from the mapping
        delete protocolAddressesByName[nameHash];
        delete protocolAddressesNames[addr];

        emit OnProtocolAddressDeleted(addr, addressType);
    }

    /**
     * @notice Updates the address of a protocol address given its name
     * @param name The name of the protocol address to be updated
     * @param newAddr The new address to be set
     * @dev This function can only be called by the owner of the contract.
     * @dev The name must already exist in the AddressManager.
     */
    function updateProtocolAddress(string memory name, address newAddr) external onlyOwner {
        require(newAddr != address(0), AddressManager__AddressZero());

        bytes32 nameHash = keccak256(abi.encode(name));

        ProtocolAddress storage protocolAddress = protocolAddressesByName[nameHash];

        require(
            protocolAddress.addr != address(0) && protocolAddress.name == nameHash,
            AddressManager__AddressDoesNotExist()
        );
        require(protocolAddress.addr != newAddr, AddressManager__AddressAlreadyExists());

        // Remove the old address from the protocolAddressesNames mapping
        delete protocolAddressesNames[protocolAddress.addr];

        // Update the address in the protocolAddresses mapping
        protocolAddress.addr = newAddr;

        // Update the mapping for protocolAddressesNames
        protocolAddressesNames[newAddr] = nameHash;

        emit OnProtocolAddressUpdated(name, newAddr);
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
        require(!_protocolRoles.contains(newRole), AddressManager__RoleAlreadyExists());
        success = _protocolRoles.add(newRole);

        emit OnRoleCreated(newRole);
    }

    /**
     * @notice Removes an existing role from the AddressManager
     * @param roleToRemove The role to be removed
     * @dev This function can only be called by the owner of the contract.
     * @return success A boolean indicating whether the role was successfully removed
     */
    function removeRole(bytes32 roleToRemove) external onlyOwner returns (bool success) {
        require(_protocolRoles.contains(roleToRemove), AddressManager__RoleDoesNotExist());
        success = _protocolRoles.remove(roleToRemove);

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
        require(_protocolRoles.contains(role), AddressManager__RoleDoesNotExist());

        // Check if the role is already assigned to the proposed holder
        bytes32[] memory currentRoles = rolesByAddress[proposedRoleHolder];

        for (uint256 i; i < currentRoles.length; ++i) {
            if (currentRoles[i] == role) revert AddressManager__AlreadyRoleHolder();
        }

        ProposedRoleHolder memory proposed = ProposedRoleHolder({
            proposedHolder: proposedRoleHolder,
            proposalTime: block.timestamp
        });

        // Assign the proposed holder with a delay
        proposedRoleHolders[role] = proposed;

        emit OnProposedRoleHolder(role, proposedRoleHolder);
    }

    /**
     * @notice Accepts a proposed role after the acceptance delay.
     * @param role The role to be accepted.
     * @dev This function can only be called by the proposed holder of the role.
     */
    function acceptProposedRole(bytes32 role) external returns (bool success) {
        require(_protocolRoles.contains(role), AddressManager__RoleDoesNotExist());

        ProposedRoleHolder memory proposedHolder = proposedRoleHolders[role];

        // There must be a proposed holder for the role, and the caller must be the proposed holder
        require(proposedHolder.proposedHolder != address(0), AddressManager__NoProposedHolder());
        require(proposedHolder.proposedHolder == msg.sender, AddressManager__InvalidCaller());

        // Check if the proposal time has passed
        require(
            block.timestamp <= proposedHolder.proposalTime + roleAcceptanceDelay,
            AddressManager__TooLateToAccept()
        );

        // Revoke the role for the current holder if it exists
        address currentHolder = currentRoleHolders[role];

        if (currentHolder != address(0)) _revokeRole(role, currentHolder);

        // Assign the role to the proposed holder
        success = _grantRole(role, msg.sender);

        // Update the current role holder mapping
        currentRoleHolders[role] = msg.sender;
        rolesByAddress[msg.sender].push(role);

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
        require(_protocolRoles.contains(role), AddressManager__RoleDoesNotExist());
        require(currentRoleHolders[role] == account, AddressManager__NotRoleHolder());

        _revokeRole(role, account);

        // Remove the role from the rolesByAddress mapping
        bytes32[] storage roles = rolesByAddress[account];
        for (uint256 i = 0; i < roles.length; i++) {
            if (roles[i] == role) {
                roles[i] = roles[roles.length - 1]; // Move the last element to the current position
                roles.pop(); // Remove the last element
                break;
            }
        }

        // Clear the current role holder mapping
        delete currentRoleHolders[role];
    }

    /*//////////////////////////////////////////////////////////////
                          FOR EXTERNAL CHECKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Checks if a specific address has a specific name
     * @param addr The address to check
     * @param name The name to check against the address
     * @return bool A boolean indicating whether the address has the name
     * @dev To be able to use this function in require statements, it is implemented in a way that does not revert.
     */
    function hasName(address addr, string memory name) external view returns (bool) {
        bytes32 expectedNameHash = protocolAddressesNames[addr]; // Access the mapping to ensure it exists
        bytes32 givenNameHash = keccak256(abi.encode(name));

        if (
            addr == address(0) ||
            bytes(name).length == 0 ||
            bytes(name).length > 32 ||
            expectedNameHash != givenNameHash
        ) return false; // Address is zero

        return true; // Address has the name
    }

    /**
     * @notice Checks if an account has a specific role
     * @param role The role to check
     * @param account The address of the account
     * @return bool A boolean indicating whether the account has the role
     * @dev If the role is not a protocol role, it will return false.
     */
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        if (!_protocolRoles.contains(role)) return false;
        else return super.hasRole(role, account);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function getProtocolAddressByName(
        string memory name
    ) external view returns (ProtocolAddress memory protocolAddress) {
        bytes32 nameHash = keccak256(abi.encode(name));
        protocolAddress = protocolAddressesByName[nameHash];
    }

    function getProposedRoleHolder(
        bytes32 role
    ) external view returns (ProposedRoleHolder memory proposedHolder) {
        proposedHolder = proposedRoleHolders[role];
    }

    function getRolesByAddress(address roleHolder) external view returns (bytes32[] memory roles) {
        roles = rolesByAddress[roleHolder];
    }

    /**
     * @notice Checks if a role exists in the AddressManager
     * @param role The role to check for existence
     * @return bool A boolean indicating whether the role exists
     */
    function isValidRole(bytes32 role) external view returns (bool) {
        return _protocolRoles.contains(role);
    }

    /**
     * @notice Returns the list of roles in the AddressManager
     * @return roles An array of bytes32 representing the roles
     */
    function getRoles() external view returns (bytes32[] memory roles) {
        roles = new bytes32[](_protocolRoles.length());
        for (uint256 i = 0; i < _protocolRoles.length(); i++) {
            roles[i] = _protocolRoles.at(i);
        }
    }
}
