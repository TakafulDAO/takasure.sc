// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {RevenueModule} from "contracts/modules/RevenueModule.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeRevenueModule is Script, GetContractAddress {
    function run() external returns (address) {
        address revenueModuleAddress = _getContractAddress(block.chainid, "RevenueModule");
        address oldImplementation = Upgrades.getImplementationAddress(revenueModuleAddress);
        console2.log("Old RevenueModule implementation address: ", oldImplementation);

        vm.startBroadcast();

        Upgrades.upgradeProxy(revenueModuleAddress, "RevenueModule.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(revenueModuleAddress);
        console2.log("New RevenueModule implementation address: ", newImplementation);

        return (newImplementation);
    }
}
