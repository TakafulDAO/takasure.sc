// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {
    SaveFundsInvestAutomationRunner
} from "contracts/helpers/chainlink/automation/SaveFundsInvestAutomationRunner.sol";

contract UpgradeSaveFundsInvestAutomationRunner is Script, GetContractAddress {
    function run() external returns (address newImplementation) {
        address proxy = _getContractAddress(block.chainid, "SaveFundsInvestAutomationRunner");
        address oldImplementation = Upgrades.getImplementationAddress(proxy);
        console2.log("Old SaveFundsInvestAutomationRunner implementation address:");
        console2.logAddress(oldImplementation);

        vm.startBroadcast();

        // Upgrades.upgradeProxy(proxy, "SaveFundsInvestAutomationRunner.sol", "");
        Upgrades.upgradeProxy(
            proxy,
            "SaveFundsInvestAutomationRunner.sol",
            abi.encodeCall(SaveFundsInvestAutomationRunner.initializeV2, ())
        );

        vm.stopBroadcast();

        newImplementation = Upgrades.getImplementationAddress(proxy);
        console2.log("New SaveFundsInvestAutomationRunner implementation address:");
        console2.logAddress(newImplementation);

        return newImplementation;
    }
}
