// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {Options} from "openzeppelin-foundry-upgrades/Defender.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract PrepareRevShareModuleUpgrade is Script {
    function run() external returns (address newImplementation) {
        Options memory opts;

        Upgrades.validateUpgrade("RevShareModule.sol", opts);

        console2.log("RevShareModule.sol is upgradeable");

        vm.startBroadcast();

        RevShareModule revShareModule = new RevShareModule();

        vm.stopBroadcast();

        return address(revShareModule);
    }
}
