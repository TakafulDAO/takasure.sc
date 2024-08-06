// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {BenefitMultiplierConsumer} from "contracts/takasure/oracle/BenefitMultiplierConsumer.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployBenefitMultiplierConsumer is Script {
    using stdJson for string;

    function run() external returns (BenefitMultiplierConsumer) {
        HelperConfig helperConfig = new HelperConfig();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        string memory root = vm.projectRoot();
        string memory scriptPath = string.concat(
            root,
            "/scripts/chainlink-functions/bmFetchCode.js"
        );
        string memory bmFetchScript = vm.readFile(scriptPath);

        vm.startBroadcast();

        console2.log("Deploying BenefitMultiplierConsumer...");

        BenefitMultiplierConsumer benefitMultiplierConsumer = new BenefitMultiplierConsumer(
            config.functionsRouter,
            config.donId,
            config.gasLimit,
            config.subscriptionId
        );

        console2.log("BenefitMultiplierConsumer deployed");

        console2.log("Adding New source code to BenefitMultiplierConsumer...");

        benefitMultiplierConsumer.setBMSourceRequestCode(bmFetchScript);

        console2.log("New Source Code added");

        vm.stopBroadcast();

        return (benefitMultiplierConsumer);
    }
}
