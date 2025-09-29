// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {ProtocolAddressType, ProtocolAddress, ProposedRoleHolder} from "contracts/types/TakasureTypes.sol";

contract AddressManagerFuzzTest is Test {
    AddressManager addressManager;

    address adminAddress = makeAddr("adminAddress");

    function setUp() public {
        address addressManagerImplementation = address(new AddressManager());
        address addressManagerAddress = UnsafeUpgrades.deployUUPSProxy(
            addressManagerImplementation,
            abi.encodeCall(AddressManager.initialize, (msg.sender))
        );
        addressManager = AddressManager(addressManagerAddress);
    }

    function testChangeRoleAcceptanceDelayRevertIfCallerIsWrong(address caller) public {
        vm.assume(caller != addressManager.owner());

        vm.prank(caller);
        vm.expectRevert();
        addressManager.setRoleAcceptanceDelay(2 days);
    }

    function testAddAdminAddressRevertIfCallerIsWrong(address caller) public {
        vm.assume(caller != addressManager.owner());

        vm.prank(caller);
        vm.expectRevert();
        addressManager.addProtocolAddress("Admin", adminAddress, ProtocolAddressType.Admin);
    }

    modifier addAdminAddress() {
        vm.prank(addressManager.owner());
        addressManager.addProtocolAddress("Admin", adminAddress, ProtocolAddressType.Admin);
        _;
    }

    function testDeleteAddressRevertIfCallerIsWrong(address caller) public addAdminAddress {
        vm.assume(caller != addressManager.owner());

        vm.prank(caller);
        vm.expectRevert();
        addressManager.deleteProtocolAddress(adminAddress);
    }

    function testUpdateAddressRevertIfCallerIsWrong(address caller) public addAdminAddress {
        vm.assume(caller != addressManager.owner());

        vm.prank(caller);
        vm.expectRevert();
        addressManager.updateProtocolAddress("Admin", adminAddress);
    }

    function testCreateNewRoleRevertIfCallerIsWrong(address caller) public {
        vm.assume(caller != addressManager.owner());

        vm.prank(caller);
        vm.expectRevert();
        addressManager.createNewRole(keccak256("TestRole"));
    }

    modifier addRole() {
        vm.prank(addressManager.owner());
        addressManager.createNewRole(keccak256("TestRole"));
        _;
    }

    function testRemoveRoleRevertIfCallerIsWrong(address caller) public addRole {
        vm.assume(caller != addressManager.owner());

        vm.prank(caller);
        vm.expectRevert();
        addressManager.removeRole(keccak256("TestRole"));
    }

    function testProposeRoleHolderRevertIfCallerIsWrong(address caller) public addRole {
        vm.assume(caller != addressManager.owner());

        vm.prank(caller);
        vm.expectRevert();
        addressManager.proposeRoleHolder(keccak256("TestRole"), makeAddr("proposedHolder"));
    }

    modifier acceptRole() {
        vm.prank(addressManager.owner());
        addressManager.createNewRole(keccak256("TestRole"));

        address proposedHolder = makeAddr("proposedHolder");
        vm.prank(addressManager.owner());
        addressManager.proposeRoleHolder(keccak256("TestRole"), proposedHolder);

        vm.prank(proposedHolder);
        addressManager.acceptProposedRole(keccak256("TestRole"));
        _;
    }

    function testRevokeRoleHolderRevertIfCallerIsWrong(address caller) public acceptRole {
        vm.assume(caller != addressManager.owner());

        address roleHolder = addressManager.currentRoleHolders(keccak256("TestRole"));

        vm.prank(caller);
        vm.expectRevert();
        addressManager.revokeRoleHolder(keccak256("TestRole"), roleHolder);
    }
}
