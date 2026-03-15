// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {Defender, Options, ApprovalProcessResponse} from "openzeppelin-foundry-upgrades/Defender.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract PrepareModuleManagerUpgrade is Script {
    function run() external returns (address newImplementation) {
        Options memory opts;

        Upgrades.validateUpgrade("ModuleManager.sol", opts);

        console2.log("ModuleManager.sol is upgradeable");

        vm.startBroadcast();

        ModuleManager moduleManager = new ModuleManager();

        vm.stopBroadcast();

        return address(moduleManager);
    }
}
