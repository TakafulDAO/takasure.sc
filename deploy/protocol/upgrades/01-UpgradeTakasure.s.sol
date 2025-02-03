// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {TakasureReserve} from "contracts/takasure/core/TakasureReserve.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";

contract UpgradeTakasure is Script, GetContractAddress {
    function run() external returns (address) {
        address takasureAddress = _getContractAddress(block.chainid, "TakasureReserve");
        address oldImplementation = Upgrades.getImplementationAddress(takasureAddress);
        console2.log("Old TakasureReserve implementation address: ", oldImplementation);

        vm.startBroadcast();

        Upgrades.upgradeProxy(takasureAddress, "TakasureReserve.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(takasureAddress);
        console2.log("New TakasureReserve implementation address: ", newImplementation);

        return (newImplementation);
    }
}
