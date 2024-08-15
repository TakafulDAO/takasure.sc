// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {BenefitMultiplierConsumer} from "contracts/takasure/oracle/BenefitMultiplierConsumer.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract RequestBenefitMultiplier is Script, GetContractAddress {
    address public testAddress = 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1;

    function run() public {
        address bmConsumerAddress = _getContractAddress(block.chainid, "BenefitMultiplierConsumer");
        BenefitMultiplierConsumer bmConsumer = BenefitMultiplierConsumer(bmConsumerAddress);
        vm.startBroadcast();

        console2.log("Requesting Benefit Multiplier for test address...");
        console2.log("Test address: ", testAddress);

        string[] memory args = new string[](1);
        args[0] = Strings.toHexString(uint256(uint160(testAddress)), 20);

        vm.startBroadcast();

        bmConsumer.sendRequest(args);

        uint256 benefitMultiplier = bmConsumer.convertResponseToUint();

        vm.stopBroadcast();
    }
}
