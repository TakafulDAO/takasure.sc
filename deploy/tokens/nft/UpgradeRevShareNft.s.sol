// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeRevShareNFT is Script, GetContractAddress {
    function run() external returns (address) {
        address revShareNFTAddress = _getContractAddress(block.chainid, "RevShareNFT");
        address oldImplementation = Upgrades.getImplementationAddress(revShareNFTAddress);
        console2.log("Old RevShareNFT implementation address: ", oldImplementation);

        vm.startBroadcast();

        // Upgrade RevShareNFT
        Upgrades.upgradeProxy(revShareNFTAddress, "RevShareNFT.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(revShareNFTAddress);
        console2.log("New RevShareNFT implementation address: ", newImplementation);

        return (newImplementation);
    }
}
