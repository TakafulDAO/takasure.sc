// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract ForkRehearsalDeploy is Script {
    function run(address addressManager) external returns (address moduleManager, address revShareModule) {
        vm.startBroadcast();

        moduleManager = Upgrades.deployUUPSProxy(
            "ModuleManager.sol", abi.encodeCall(ModuleManager.initialize, (addressManager))
        );

        revShareModule = Upgrades.deployUUPSProxy(
            "RevShareModule.sol", abi.encodeCall(RevShareModule.initialize, (addressManager, "MODULE__REVSHARE"))
        );

        vm.stopBroadcast();

        return (moduleManager, revShareModule);
    }
}
