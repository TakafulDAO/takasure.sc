// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeSFVault is Script, GetContractAddress {
    function run() external returns (address) {
        address sfVaultAddress = _getContractAddress(block.chainid, "SFVault");
        address oldImplementation = Upgrades.getImplementationAddress(sfVaultAddress);
        console2.log("Old SFVault implementation address: ", oldImplementation);

        vm.startBroadcast();

        // Upgrade SFVault
        Upgrades.upgradeProxy(sfVaultAddress, "SFVault.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(sfVaultAddress);
        console2.log("New SFVault implementation address: ", newImplementation);

        return (newImplementation);
    }
}
