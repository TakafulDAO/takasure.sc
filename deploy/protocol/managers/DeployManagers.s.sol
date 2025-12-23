// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployManagers is Script {
    function run() external returns (address addressManager, address moduleManager) {
        vm.startBroadcast();

        addressManager =
            Upgrades.deployUUPSProxy("AddressManager.sol", abi.encodeCall(AddressManager.initialize, (msg.sender)));

        moduleManager =
            Upgrades.deployUUPSProxy("ModuleManager.sol", abi.encodeCall(ModuleManager.initialize, (addressManager)));

        vm.stopBroadcast();

        return (addressManager, moduleManager);
    }
}
