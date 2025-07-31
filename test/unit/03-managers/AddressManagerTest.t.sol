// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";

import {ProtocolAddressType, ProtocolAddress, ProposedRoleHolder} from "contracts/types/TakasureTypes.sol";

contract AddressManagerTest is Test {
    DeployManagers managerDeployer;
    AddressManager addressManager;

    address addressManagerOwner;
    address protocolAddress = makeAddr("protocolAddress");
    address adminAddress = makeAddr("adminAddress");

    event OnNewRoleAcceptanceDelay(uint256 newDelay);
    event OnNewProtocolAddress(
        string indexed name,
        address indexed addr,
        ProtocolAddressType addressType
    );
    event OnProtocolAddressDeleted(
        bytes32 indexed nameHash,
        address indexed addr,
        ProtocolAddressType addressType
    );
    event OnProtocolAddressUpdated(string indexed name, address indexed newAddr);
    event OnRoleCreated(bytes32 indexed role);
    event OnRoleRemoved(bytes32 indexed role);
    event OnProposedRoleHolder(bytes32 indexed role, address indexed proposedHolder);
    event OnNewRoleHolder(bytes32 indexed role, address indexed newHolder);

    function setUp() public {
        managerDeployer = new DeployManagers();
        (, addressManager, ) = managerDeployer.run();
        addressManagerOwner = addressManager.owner();
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    function testRevertIfRoleAcceptanceDelayIsZero() public {
        vm.prank(addressManagerOwner);
        vm.expectRevert(AddressManager.AddressManager__InvalidDelay.selector);
        addressManager.setRoleAcceptanceDelay(0);
    }

    function testAddProtocolAddressRevertsIfThereIsNoName() public {
        vm.prank(addressManagerOwner);
        vm.expectRevert(AddressManager.AddressManager__InvalidNameLength.selector);
        addressManager.addProtocolAddress("", adminAddress, ProtocolAddressType.Admin);
    }

    function testAddProtocolAddressRevertsIfNameIsBiggerThan32Bytes() public {
        vm.prank(addressManagerOwner);
        vm.expectRevert(AddressManager.AddressManager__InvalidNameLength.selector);
        addressManager.addProtocolAddress(
            "ThisNameIsWayTooLongAndDefinitelyMoreThanThirtyTwoBytes",
            adminAddress,
            ProtocolAddressType.Admin
        );
    }

    function testAddProtocolAddressRevertsIfAddressIsZero() public {
        vm.prank(addressManagerOwner);
        vm.expectRevert(AddressManager.AddressManager__AddressZero.selector);
        addressManager.addProtocolAddress("Admin", address(0), ProtocolAddressType.Admin);
    }

    function testAddProtocolAddressRevertsIfAddressIsAlreadySet() public {
        vm.startPrank(addressManagerOwner);
        addressManager.addProtocolAddress("Admin", adminAddress, ProtocolAddressType.Admin);

        vm.expectRevert(AddressManager.AddressManager__AddressAlreadyExists.selector);
        addressManager.addProtocolAddress("Admin", adminAddress, ProtocolAddressType.Admin);
        vm.stopPrank();
    }

    function testDeleteAddressRevertsIfAddressZero() public {
        vm.prank(addressManagerOwner);
        vm.expectRevert(AddressManager.AddressManager__AddressZero.selector);
        addressManager.deleteProtocolAddress(address(0));
    }

    function testUpdateAddressRevertsIfAddressZero() public {
        vm.prank(addressManagerOwner);
        vm.expectRevert(AddressManager.AddressManager__AddressZero.selector);
        addressManager.updateProtocolAddress("Admin", address(0));
    }

    function testUpdateAddressRevertsIfNameIsInconsistent() public {
        vm.startPrank(addressManagerOwner);
        addressManager.addProtocolAddress("Admin", adminAddress, ProtocolAddressType.Admin);
        // Try to update the address with a different name
        vm.expectRevert(AddressManager.AddressManager__AddressDoesNotExist.selector);
        addressManager.updateProtocolAddress("WrongName", adminAddress);
        vm.stopPrank();
    }

    function testUpdateAddressRevertsIfUpdatesToSameAddress() public {
        vm.startPrank(addressManagerOwner);
        addressManager.addProtocolAddress("Admin", adminAddress, ProtocolAddressType.Admin);
        // Try to update the address to the same address
        vm.expectRevert(AddressManager.AddressManager__AddressAlreadyExists.selector);
        addressManager.updateProtocolAddress("Admin", adminAddress);
        vm.stopPrank();
    }

    function testCreateNewRoleRevertsIfRoleAlreadyExists() public {
        vm.startPrank(addressManagerOwner);
        addressManager.createNewRole(keccak256("TestRole"));
        vm.expectRevert(AddressManager.AddressManager__RoleAlreadyExists.selector);
        addressManager.createNewRole(keccak256("TestRole"));
        vm.stopPrank();
    }

    function testRemoveRoleRevertsIfRoleDoesNotExist() public {
        vm.prank(addressManagerOwner);
        vm.expectRevert(AddressManager.AddressManager__RoleDoesNotExist.selector);
        addressManager.removeRole(keccak256("NonExistentRole"));
    }

    function testProposeRoleHolderRevertsIfRoleDoesNotExist() public {
        address proposedHolder = makeAddr("proposedHolder");
        vm.prank(addressManagerOwner);
        vm.expectRevert(AddressManager.AddressManager__RoleDoesNotExist.selector);
        addressManager.proposeRoleHolder(keccak256("NonExistentRole"), proposedHolder);
    }

    function testAcceptRoleRevertsIfRoleDoesNotExist() public {
        address proposedHolder = makeAddr("proposedHolder");

        vm.prank(proposedHolder);
        vm.expectRevert(AddressManager.AddressManager__RoleDoesNotExist.selector);
        addressManager.acceptProposedRole(keccak256("NonExistentRole"));
    }

    function testAcceptRoleRevertsIfNoneProposedHolder() public {
        vm.prank(addressManagerOwner);
        addressManager.createNewRole(keccak256("TestRole"));

        address proposedHolder = makeAddr("proposedHolder");

        vm.prank(proposedHolder);
        vm.expectRevert(AddressManager.AddressManager__NoProposedHolder.selector);
        addressManager.acceptProposedRole(keccak256("TestRole"));
    }

    function testAcceptRoleRevertsIfCallerIsNotProposedHolder() public {
        address proposedHolder = makeAddr("proposedHolder");

        vm.startPrank(addressManagerOwner);
        addressManager.createNewRole(keccak256("TestRole"));
        addressManager.proposeRoleHolder(keccak256("TestRole"), proposedHolder);
        vm.stopPrank();

        address notProposedHolder = makeAddr("notProposedHolder");

        vm.prank(notProposedHolder);
        vm.expectRevert(AddressManager.AddressManager__InvalidCaller.selector);
        addressManager.acceptProposedRole(keccak256("TestRole"));
    }

    function testAcceptRoleRevertsIfTimeToAcceptHasExpired() public {
        address proposedHolder = makeAddr("proposedHolder");

        vm.startPrank(addressManagerOwner);
        addressManager.createNewRole(keccak256("TestRole"));
        addressManager.proposeRoleHolder(keccak256("TestRole"), proposedHolder);
        vm.stopPrank();

        // Fast forward time to simulate expiration
        vm.warp(block.timestamp + 2 days);
        vm.roll(block.number + 1);

        vm.prank(proposedHolder);
        vm.expectRevert(AddressManager.AddressManager__TooLateToAccept.selector);
        addressManager.acceptProposedRole(keccak256("TestRole"));
    }

    function testRevokeRoleRevertsIfRoleDoesNotExist() public {
        address roleHolder = makeAddr("roleHolder");

        vm.prank(addressManagerOwner);
        vm.expectRevert(AddressManager.AddressManager__RoleDoesNotExist.selector);
        addressManager.revokeRoleHolder(keccak256("NonExistentRole"), roleHolder);
    }

    function testRevokeRoleRevertsIfHolderIsNotCurrentHolder() public {
        address roleHolder = makeAddr("roleHolder");

        vm.startPrank(addressManagerOwner);
        addressManager.createNewRole(keccak256("TestRole"));
        addressManager.proposeRoleHolder(keccak256("TestRole"), roleHolder);
        vm.stopPrank();

        // Accept the role to make the roleHolder the current holder
        vm.prank(roleHolder);
        addressManager.acceptProposedRole(keccak256("TestRole"));

        address notCurrentHolder = makeAddr("notCurrentHolder");

        vm.prank(addressManagerOwner);
        vm.expectRevert(AddressManager.AddressManager__NotRoleHolder.selector);
        addressManager.revokeRoleHolder(keccak256("TestRole"), notCurrentHolder);
    }

    function testDeleteNonexistentAddressReverts() public {
        vm.prank(addressManagerOwner);
        vm.expectRevert(AddressManager.AddressManager__AddressDoesNotExist.selector);
        addressManager.deleteProtocolAddress(address(0x999));
    }

    /*//////////////////////////////////////////////////////////////
                            ACCEPTANCE DELAY
    //////////////////////////////////////////////////////////////*/

    function testSetRoleAcceptanceDelayAndEmitEvent() public {
        uint256 initialDelay = addressManager.roleAcceptanceDelay();

        vm.prank(addressManagerOwner);
        vm.expectEmit(false, false, false, false, address(addressManager));
        emit OnNewRoleAcceptanceDelay(2 days);
        addressManager.setRoleAcceptanceDelay(2 days);

        uint256 newDelay = addressManager.roleAcceptanceDelay();

        assertEq(initialDelay, 1 days);
        assertEq(newDelay, 2 days);
    }

    /*//////////////////////////////////////////////////////////////
                            ADD NEW ADDRESS
    //////////////////////////////////////////////////////////////*/

    function testAddAdminAddressAndEmitEvent() public {
        vm.prank(addressManagerOwner);
        vm.expectEmit(true, true, false, false, address(addressManager));
        emit OnNewProtocolAddress("Admin", adminAddress, ProtocolAddressType.Admin);
        addressManager.addProtocolAddress("Admin", adminAddress, ProtocolAddressType.Admin);

        bytes32 addressName = addressManager.protocolAddressesNames(adminAddress);

        ProtocolAddress memory protocolAddressToCheck = addressManager.getProtocolAddressByName(
            "Admin"
        );

        assert(addressName == keccak256(abi.encode("Admin")));
        assert(protocolAddressToCheck.name == keccak256(abi.encode("Admin")));
        assert(protocolAddressToCheck.addr == adminAddress);
        assert(protocolAddressToCheck.addressType == ProtocolAddressType.Admin);
    }

    function testAddProtocolAddressAndEmitEvent() public {
        vm.prank(addressManagerOwner);
        vm.expectEmit(true, true, false, false, address(addressManager));
        emit OnNewProtocolAddress("Protocol", protocolAddress, ProtocolAddressType.Protocol);
        addressManager.addProtocolAddress(
            "Protocol",
            protocolAddress,
            ProtocolAddressType.Protocol
        );

        bytes32 addressName = addressManager.protocolAddressesNames(protocolAddress);

        ProtocolAddress memory protocolAddressToCheck = addressManager.getProtocolAddressByName(
            "Protocol"
        );

        assert(addressName == keccak256(abi.encode("Protocol")));
        assert(protocolAddressToCheck.name == keccak256(abi.encode("Protocol")));
        assert(protocolAddressToCheck.addr == protocolAddress);
        assert(protocolAddressToCheck.addressType == ProtocolAddressType.Protocol);
    }

    modifier addAdminAddress() {
        vm.prank(addressManagerOwner);
        addressManager.addProtocolAddress("Admin", adminAddress, ProtocolAddressType.Admin);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            DELETE ADDRESSES
    //////////////////////////////////////////////////////////////*/

    function testDeleteAddressAndEmitEvent() public addAdminAddress {
        // Check that the address is added correctly
        bytes32 addressName = addressManager.protocolAddressesNames(adminAddress);

        ProtocolAddress memory protocolAddressToCheck = addressManager.getProtocolAddressByName(
            "Admin"
        );

        assert(addressName == keccak256(abi.encode("Admin")));
        assert(protocolAddressToCheck.name == keccak256(abi.encode("Admin")));
        assert(protocolAddressToCheck.addr == adminAddress);
        assert(protocolAddressToCheck.addressType == ProtocolAddressType.Admin);

        // Now delete the address and check that the event is emitted
        vm.prank(addressManagerOwner);
        vm.expectEmit(true, true, false, false, address(addressManager));
        emit OnProtocolAddressDeleted(addressName, adminAddress, ProtocolAddressType.Admin);
        addressManager.deleteProtocolAddress(adminAddress);

        // Check that the address is deleted
        addressName = addressManager.protocolAddressesNames(adminAddress);

        vm.expectRevert(AddressManager.AddressManager__AddressDoesNotExist.selector);
        protocolAddressToCheck = addressManager.getProtocolAddressByName("Admin");
    }

    /*//////////////////////////////////////////////////////////////
                            UPDATE ADDRESSES
    //////////////////////////////////////////////////////////////*/

    function testUpdateAddressAndEmitEvent() public addAdminAddress {
        // Check that the address is added correctly
        bytes32 addressName = addressManager.protocolAddressesNames(adminAddress);

        ProtocolAddress memory protocolAddressToCheck = addressManager.getProtocolAddressByName(
            "Admin"
        );

        assert(addressName == keccak256(abi.encode("Admin")));
        assert(protocolAddressToCheck.name == keccak256(abi.encode("Admin")));
        assert(protocolAddressToCheck.addr == adminAddress);
        assert(protocolAddressToCheck.addressType == ProtocolAddressType.Admin);

        // Now update the address and check that the event is emitted
        address newAdminAddress = makeAddr("newAdminAddress");

        vm.prank(addressManagerOwner);
        vm.expectEmit(true, true, false, false, address(addressManager));
        emit OnProtocolAddressUpdated("Admin", newAdminAddress);
        addressManager.updateProtocolAddress("Admin", newAdminAddress);

        // Check that the address is updated
        addressName = addressManager.protocolAddressesNames(newAdminAddress);
        protocolAddressToCheck = addressManager.getProtocolAddressByName("Admin");

        assert(addressName == keccak256(abi.encode("Admin")));
        assert(protocolAddressToCheck.name == keccak256(abi.encode("Admin")));
        assert(protocolAddressToCheck.addr == newAdminAddress);

        // Check that the old address is not in the mapping anymore
        bytes32 oldAddressName = addressManager.protocolAddressesNames(adminAddress);

        assert(oldAddressName == 0x00);
    }

    /*//////////////////////////////////////////////////////////////
                              CREATE ROLES
    //////////////////////////////////////////////////////////////*/

    function testCreateNewRole() public {
        bytes32[] memory roles = addressManager.getRoles();

        assert(roles.length == 0);
        assert(!addressManager.isValidRole(keccak256("TestRole")));

        vm.prank(addressManagerOwner);
        vm.expectEmit(true, false, false, true, address(addressManager));
        emit OnRoleCreated(keccak256("TestRole"));
        bool roleCreated = addressManager.createNewRole(keccak256("TestRole"));

        bool isValidRole = addressManager.isValidRole(keccak256("TestRole"));

        roles = addressManager.getRoles();
        assert(roleCreated);
        assert(isValidRole);
        assert(roles.length == 1);
        assert(roles[0] == keccak256("TestRole"));
    }

    modifier addRole() {
        vm.prank(addressManagerOwner);
        addressManager.createNewRole(keccak256("TestRole"));
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              REMOVE ROLES
    //////////////////////////////////////////////////////////////*/

    function testRemoveRole() public addRole {
        bytes32[] memory roles = addressManager.getRoles();
        assert(roles.length == 1);
        assert(roles[0] == keccak256("TestRole"));
        assert(addressManager.isValidRole(keccak256("TestRole")));

        vm.prank(addressManagerOwner);
        vm.expectEmit(true, false, false, true, address(addressManager));
        emit OnRoleRemoved(keccak256("TestRole"));
        bool roleRemoved = addressManager.removeRole(keccak256("TestRole"));

        bool isValidRole = addressManager.isValidRole(keccak256("TestRole"));
        roles = addressManager.getRoles();

        assert(roleRemoved);
        assert(!isValidRole);
        assert(roles.length == 0);
    }

    /*//////////////////////////////////////////////////////////////
                          PROPOSE ROLE HOLDER
    //////////////////////////////////////////////////////////////*/

    function testProposeRoleHolder() public addRole {
        ProposedRoleHolder memory proposedHolderData = addressManager.getProposedRoleHolder(
            keccak256("TestRole")
        );

        assert(proposedHolderData.proposedHolder == address(0));
        assert(proposedHolderData.proposalTime == 0);

        address proposedHolder = makeAddr("proposedHolder");

        vm.prank(addressManagerOwner);
        vm.expectEmit(true, true, false, false, address(addressManager));
        emit OnProposedRoleHolder(keccak256("TestRole"), proposedHolder);
        addressManager.proposeRoleHolder(keccak256("TestRole"), proposedHolder);

        proposedHolderData = addressManager.getProposedRoleHolder(keccak256("TestRole"));

        assertEq(proposedHolderData.proposedHolder, proposedHolder);
        assert(proposedHolderData.proposalTime > 0);
        assertEq(proposedHolderData.proposalTime, block.timestamp);
    }

    modifier newRoleAndProposedRoleHolder() {
        vm.prank(addressManagerOwner);
        addressManager.createNewRole(keccak256("TestRole"));

        address proposedHolder = makeAddr("proposedHolder");
        vm.prank(addressManagerOwner);
        addressManager.proposeRoleHolder(keccak256("TestRole"), proposedHolder);
        _;
    }

    function testCanChangeProposedRoleHolder() public newRoleAndProposedRoleHolder {
        ProposedRoleHolder memory proposedHolderData = addressManager.getProposedRoleHolder(
            keccak256("TestRole")
        );

        assert(proposedHolderData.proposedHolder != address(0));
        assert(proposedHolderData.proposalTime > 0);

        address newProposedHolder = makeAddr("newProposedHolder");

        vm.prank(addressManagerOwner);
        addressManager.proposeRoleHolder(keccak256("TestRole"), newProposedHolder);

        proposedHolderData = addressManager.getProposedRoleHolder(keccak256("TestRole"));

        assertEq(proposedHolderData.proposedHolder, newProposedHolder);
        assert(proposedHolderData.proposalTime > 0);
    }

    function testCanChangeProposedRoleHolderToZero() public newRoleAndProposedRoleHolder {
        ProposedRoleHolder memory proposedHolderData = addressManager.getProposedRoleHolder(
            keccak256("TestRole")
        );

        assert(proposedHolderData.proposedHolder != address(0));
        assert(proposedHolderData.proposalTime > 0);

        vm.prank(addressManagerOwner);
        addressManager.proposeRoleHolder(keccak256("TestRole"), address(0));

        proposedHolderData = addressManager.getProposedRoleHolder(keccak256("TestRole"));

        assertEq(proposedHolderData.proposedHolder, address(0));
        assertEq(proposedHolderData.proposalTime, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                          ACCEPT PROPOSED ROLE
    //////////////////////////////////////////////////////////////*/

    function testAcceptProposedRoleHolder() public newRoleAndProposedRoleHolder {
        ProposedRoleHolder memory proposedHolderData = addressManager.getProposedRoleHolder(
            keccak256("TestRole")
        );

        assert(proposedHolderData.proposedHolder != address(0));
        assert(proposedHolderData.proposalTime > 0);

        address newHolder = proposedHolderData.proposedHolder;

        vm.prank(newHolder);
        vm.expectEmit(true, true, false, false, address(addressManager));
        emit OnNewRoleHolder(keccak256("TestRole"), newHolder);
        bool accepted = addressManager.acceptProposedRole(keccak256("TestRole"));

        proposedHolderData = addressManager.getProposedRoleHolder(keccak256("TestRole"));
        address roleHolder = addressManager.currentRoleHolders(keccak256("TestRole"));
        bytes32[] memory roles = addressManager.getRolesByAddress(newHolder);

        assert(accepted);
        assertEq(proposedHolderData.proposedHolder, address(0));
        assertEq(proposedHolderData.proposalTime, 0);
        assertEq(roleHolder, newHolder);
        assertEq(roles.length, 1);
        assertEq(roles[0], keccak256("TestRole"));
    }

    modifier acceptRole() {
        vm.prank(addressManagerOwner);
        addressManager.createNewRole(keccak256("TestRole"));

        address proposedHolder = makeAddr("proposedHolder");
        vm.prank(addressManagerOwner);
        addressManager.proposeRoleHolder(keccak256("TestRole"), proposedHolder);

        vm.prank(proposedHolder);
        addressManager.acceptProposedRole(keccak256("TestRole"));
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              REVOKE ROLE
    //////////////////////////////////////////////////////////////*/

    function testRevokeRoleHolder() public acceptRole {
        address roleHolder = addressManager.currentRoleHolders(keccak256("TestRole"));
        bytes32[] memory roles = addressManager.getRolesByAddress(roleHolder);

        assert(roleHolder != address(0));
        assertEq(roles.length, 1);
        assertEq(roles[0], keccak256("TestRole"));

        vm.prank(addressManagerOwner);
        addressManager.revokeRoleHolder(keccak256("TestRole"), roleHolder);

        roleHolder = addressManager.currentRoleHolders(keccak256("TestRole"));
        roles = addressManager.getRolesByAddress(roleHolder);

        assertEq(roleHolder, address(0));
        assertEq(roles.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL CHECKS
    //////////////////////////////////////////////////////////////*/

    function testCheckIfAnAddressHasNameSet() public addAdminAddress {
        assert(addressManager.hasName(adminAddress, "Admin"));
    }

    function testCheckIfAnAddressHasRoleSet() public acceptRole {
        address roleHolder = addressManager.currentRoleHolders(keccak256("TestRole"));

        assert(addressManager.hasRole(keccak256("TestRole"), roleHolder));
    }

    function testCheckIfAnAddressHasTypeSet() public addAdminAddress {
        assert(addressManager.hasType(adminAddress, ProtocolAddressType.Admin));
    }

    /*//////////////////////////////////////////////////////////////
                                UPGRADES
    //////////////////////////////////////////////////////////////*/

    function testUpgrades() public {
        address newImpl = address(new AddressManager());

        vm.prank(addressManagerOwner);
        addressManager.upgradeToAndCall(newImpl, "");
    }
}
