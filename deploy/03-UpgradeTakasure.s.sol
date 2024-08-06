// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";

contract UpgradeTakasure is Script, GetContractAddress {
    function run() external returns (address) {
        address takasureAddress = _getContractAddress(block.chainid, "TakasurePool");
        address oldImplementation = Upgrades.getImplementationAddress(takasureAddress);
        console2.log("Old TakasurePool implementation address: ", oldImplementation);

        vm.startBroadcast();

        Upgrades.upgradeProxy(takasureAddress, "TakasurePool.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(takasureAddress);
        console2.log("New TakasurePool implementation address: ", newImplementation);

        return (newImplementation);
    }
}
