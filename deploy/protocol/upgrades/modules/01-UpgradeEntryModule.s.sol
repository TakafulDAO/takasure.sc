// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeEntryModule is Script, GetContractAddress {
    function run() external returns (address) {
        address entryModuleAddress = _getContractAddress(block.chainid, "EntryModule");
        address oldImplementation = Upgrades.getImplementationAddress(entryModuleAddress);
        console2.log("Old EntryModule implementation address: ", oldImplementation);

        vm.startBroadcast();

        Upgrades.upgradeProxy(entryModuleAddress, "EntryModule.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(entryModuleAddress);
        console2.log("New EntryModule implementation address: ", newImplementation);

        return (newImplementation);
    }
}
