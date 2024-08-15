// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {BenefitMultiplierConsumer} from "contracts/takasure/oracle/BenefitMultiplierConsumer.sol";

contract AddBmRequester is Script, GetContractAddress {
    function run() public {
        address bmConsumerAddress = _getContractAddress(block.chainid, "BenefitMultiplierConsumer");
        address takasureAddress = _getContractAddress(block.chainid, "TakasurePool");
        BenefitMultiplierConsumer bmConsumer = BenefitMultiplierConsumer(bmConsumerAddress);
        vm.startBroadcast();

        bmConsumer.setNewRequester(takasureAddress);

        vm.stopBroadcast();
    }
}
