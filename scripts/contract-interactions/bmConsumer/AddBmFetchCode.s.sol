// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {BenefitMultiplierConsumer} from "contracts/takasure/oracle/BenefitMultiplierConsumer.sol";

contract AddBmFetchCode is Script, GetContractAddress {
    using stdJson for string;

    function run() public {
        string memory root = vm.projectRoot();
        string memory scriptPath = string.concat(
            root,
            "/scripts/chainlink-functions/bmFetchCode.js"
        );
        string memory bmFetchScript = vm.readFile(scriptPath);
        address bmConsumerAddress = _getContractAddress(block.chainid, "BenefitMultiplierConsumer");
        BenefitMultiplierConsumer bmConsumer = BenefitMultiplierConsumer(bmConsumerAddress);

        vm.startBroadcast();
        console2.log("Adding New source code to BenefitMultiplierConsumer...");

        bmConsumer.setBMSourceRequestCode(bmFetchScript);

        console2.log("New Source Code added");
        vm.stopBroadcast();
    }
}
