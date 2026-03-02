// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Options} from "openzeppelin-foundry-upgrades/Defender.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {SaveFundsInvestAutomationRunner} from
    "scripts/save-funds/automation/solidity/SaveFundsInvestAutomationRunner.sol";

contract PrepareSaveFundsInvestAutomationRunnerUpgrade is Script {
    function run() external returns (address newImplementation) {
        Options memory opts;

        Upgrades.validateUpgrade("SaveFundsInvestAutomationRunner.sol", opts);
        console2.log("SaveFundsInvestAutomationRunner.sol is upgradeable");

        vm.startBroadcast();

        SaveFundsInvestAutomationRunner implementation = new SaveFundsInvestAutomationRunner();

        vm.stopBroadcast();

        newImplementation = address(implementation);
        console2.log("Prepared implementation:");
        console2.logAddress(newImplementation);

        return newImplementation;
    }
}
