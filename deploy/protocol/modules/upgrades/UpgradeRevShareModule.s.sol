// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeRevShareModule is Script, GetContractAddress {
    function run() external returns (address) {
        address revShareModuleAddress = _getContractAddress(block.chainid, "RevShareModule");
        address oldImplementation = Upgrades.getImplementationAddress(revShareModuleAddress);

        console2.log("Old RevShareModule implementation address: ", oldImplementation);

        vm.startBroadcast();

        // Upgrade RevShareModule
        Upgrades.upgradeProxy(revShareModuleAddress, "RevShareModule.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(revShareModuleAddress);
        console2.log("New RevShareModule implementation address: ", newImplementation);

        return (newImplementation);
    }
}
