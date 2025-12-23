// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeAddressManager is Script, GetContractAddress {
    function run() external returns (address) {
        address addressManagerAddress = _getContractAddress(block.chainid, "AddressManager");
        address oldImplementation = Upgrades.getImplementationAddress(addressManagerAddress);

        console2.log("Old AddressManager implementation address: ", oldImplementation);

        vm.startBroadcast();

        // Upgrade AddressManager
        Upgrades.upgradeProxy(addressManagerAddress, "AddressManager.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(addressManagerAddress);
        console2.log("New AddressManager implementation address: ", newImplementation);

        return (newImplementation);
    }
}
