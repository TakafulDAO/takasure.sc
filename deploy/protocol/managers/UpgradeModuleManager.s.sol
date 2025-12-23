// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeModuleManager is Script, GetContractAddress {
    function run() external returns (address) {
        address moduleManagerAddress = _getContractAddress(block.chainid, "ModuleManager");
        address oldImplementation = Upgrades.getImplementationAddress(moduleManagerAddress);

        console2.log("Old ModuleManager implementation address: ", oldImplementation);

        vm.startBroadcast();

        // Upgrade ModuleManager
        Upgrades.upgradeProxy(moduleManagerAddress, "ModuleManager.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(moduleManagerAddress);
        console2.log("New ModuleManager implementation address: ", newImplementation);

        return (newImplementation);
    }
}
