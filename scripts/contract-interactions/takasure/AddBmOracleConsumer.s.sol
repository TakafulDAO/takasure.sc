// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";

contract AddBmOracleConsumer is Script, GetContractAddress {
    function run() public {
        address takasureAddress = _getContractAddress(block.chainid, "TakasurePool");
        address bmConsumerAddress = _getContractAddress(block.chainid, "BenefitMultiplierConsumer");
        TakasurePool takasurePool = TakasurePool(takasureAddress);
        vm.startBroadcast();

        console2.log("Adding new Benefit Multiplier Consumer contract");

        takasurePool.setNewBenefitMultiplierConsumer(bmConsumerAddress);

        console2.log("New Benefit Multiplier Consumer contract added");

        vm.stopBroadcast();
    }
}
