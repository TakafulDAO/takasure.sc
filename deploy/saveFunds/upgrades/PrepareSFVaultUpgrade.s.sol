// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Options} from "openzeppelin-foundry-upgrades/Defender.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";

contract PrepareSFVaultUpgrade is Script {
    function run() external returns (address newImplementation) {
        Options memory opts;

        Upgrades.validateUpgrade("SFVault.sol", opts);
        console2.log("SFVault.sol is upgradeable");

        vm.startBroadcast();

        SFVault implementation = new SFVault();

        vm.stopBroadcast();

        newImplementation = address(implementation);
        console2.log("Prepared implementation:");
        console2.logAddress(newImplementation);

        return newImplementation;
    }
}
