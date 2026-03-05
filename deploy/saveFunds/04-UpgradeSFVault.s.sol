// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SFVault} from "contracts/saveFunds/protocol/SFVault.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeSFVault is Script, GetContractAddress {
    function run() external returns (address) {
        address vaultAddress = _getContractAddress(block.chainid, "SFVault");
        address oldImplementation = Upgrades.getImplementationAddress(vaultAddress);

        console2.log("Old SFVault implementation address: ", oldImplementation);

        vm.startBroadcast();

        Upgrades.upgradeProxy(vaultAddress, "SFVault.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(vaultAddress);
        console2.log("New SFVault implementation address: ", newImplementation);

        return newImplementation;
    }
}
