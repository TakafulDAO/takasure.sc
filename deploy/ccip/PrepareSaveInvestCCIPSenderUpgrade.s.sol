// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SaveInvestCCIPSender} from "contracts/helpers/chainlink/ccip/SaveInvestCCIPSender.sol";
import {Options} from "openzeppelin-foundry-upgrades/Defender.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract PrepareSaveInvestCCIPSenderUpgrade is Script {
    function run() external returns (address newImplementation) {
        Options memory opts;

        Upgrades.validateUpgrade("SaveInvestCCIPSender.sol", opts);

        console2.log("SaveInvestCCIPSender.sol is upgradeable");

        vm.startBroadcast();

        SaveInvestCCIPSender saveInvestCCIPSender = new SaveInvestCCIPSender();

        vm.stopBroadcast();

        return address(saveInvestCCIPSender);
    }
}
