// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {PrejoinModule} from "contracts/modules/PrejoinModule.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradePrejoinModule is Script, GetContractAddress {
    function run() external returns (address) {
        address prejoinModuleAddress = _getContractAddress(block.chainid, "PrejoinModule");
        address oldImplementation = Upgrades.getImplementationAddress(prejoinModuleAddress);
        console2.log("Old PrejoinModule implementation address: ", oldImplementation);

        vm.startBroadcast();

        Upgrades.upgradeProxy(prejoinModuleAddress, "PrejoinModule.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(prejoinModuleAddress);
        console2.log("New PrejoinModule implementation address: ", newImplementation);

        return (newImplementation);
    }
}
