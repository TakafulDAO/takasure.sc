// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeTakasureReserve is Script, GetContractAddress {
    function run() external returns (address) {
        address takasureReserveAddress = _getContractAddress(block.chainid, "TakasureReserve");
        address oldImplementation = Upgrades.getImplementationAddress(takasureReserveAddress);
        console2.log("Old TakasureReserve implementation address: ", oldImplementation);

        vm.startBroadcast();

        Upgrades.upgradeProxy(takasureReserveAddress, "TakasureReserve.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(takasureReserveAddress);
        console2.log("New TakasureReserve implementation address: ", newImplementation);

        return (newImplementation);
    }
}
