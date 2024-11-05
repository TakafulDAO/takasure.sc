// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {BenefitMultiplierConsumer} from "contracts/takasure/oracle/BenefitMultiplierConsumer.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployBenefitMultiplierConsumer is Script {
    using stdJson for string;

    function run() external returns (BenefitMultiplierConsumer) {
        HelperConfig helperConfig = new HelperConfig();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        string memory bmFetchScriptRoot;

        if (block.chainid == 42161) {
            bmFetchScriptRoot = "/scripts/chainlink-functions/bmFetchCodeMainnet.js";
        } else if (block.chainid == 421614) {
            bmFetchScriptRoot = "/scripts/chainlink-functions/bmFetchCodeMainnet.js";
        } else {
            bmFetchScriptRoot = "/scripts/chainlink-functions/bmFetchCodeUat.js";
        }

        string memory root = vm.projectRoot();
        string memory scriptPath = string.concat(root, bmFetchScriptRoot);
        string memory bmFetchScript = vm.readFile(scriptPath);

        vm.startBroadcast();

        // Deploy BenefitMultiplierConsumer
        BenefitMultiplierConsumer benefitMultiplierConsumer = new BenefitMultiplierConsumer(
            config.functionsRouter,
            config.donId,
            config.gasLimit,
            config.subscriptionId
        );

        // Add new source code to BenefitMultiplierConsumer
        benefitMultiplierConsumer.setBMSourceRequestCode(bmFetchScript);

        vm.stopBroadcast();

        return (benefitMultiplierConsumer);
    }
}
