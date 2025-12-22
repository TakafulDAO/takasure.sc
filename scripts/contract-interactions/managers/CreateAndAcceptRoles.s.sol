// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract CreateAndAcceptRoles is Script, GetContractAddress {
    function run() public {
        address addressManagerAddress = _getContractAddress(block.chainid, "AddressManager");

        AddressManager addressManager = AddressManager(addressManagerAddress);

        vm.startBroadcast();

        addressManager.createNewRole(Roles.OPERATOR);
        addressManager.createNewRole(Roles.BACKEND_ADMIN);
        addressManager.createNewRole(Roles.PAUSE_GUARDIAN);
        addressManager.createNewRole(Roles.KEEPER);

        addressManager.proposeRoleHolder(Roles.OPERATOR, msg.sender);
        addressManager.proposeRoleHolder(Roles.BACKEND_ADMIN, msg.sender);
        addressManager.proposeRoleHolder(Roles.PAUSE_GUARDIAN, msg.sender);
        addressManager.proposeRoleHolder(Roles.KEEPER, msg.sender);

        addressManager.acceptProposedRole(Roles.OPERATOR);
        addressManager.acceptProposedRole(Roles.BACKEND_ADMIN);
        addressManager.acceptProposedRole(Roles.PAUSE_GUARDIAN);
        addressManager.acceptProposedRole(Roles.KEEPER);

        vm.stopBroadcast();
    }
}
