// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumer} from "contracts/takasure/oracle/BenefitMultiplierConsumer.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";

contract DeployAll is Script {
    function run() external returns (address proxy) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        string memory bmFetchScriptRoot;

        if (block.chainid == 42161) {
            bmFetchScriptRoot = "/scripts/chainlink-functions/bmFetchCodeMainnet.js";
        } else if (block.chainid == 421614) {
            bmFetchScriptRoot = "/scripts/chainlink-functions/bmFetchCodeUat.js";
        } else {
            bmFetchScriptRoot = "/scripts/chainlink-functions/bmFetchCodeUat.js";
        }

        string memory root = vm.projectRoot();
        string memory scriptPath = string.concat(root, bmFetchScriptRoot);
        string memory bmFetchScript = vm.readFile(scriptPath);

        vm.startBroadcast();

        // Deploy TakasurePool
        proxy = Upgrades.deployUUPSProxy(
            "TakasurePool.sol",
            abi.encodeCall(
                TakasurePool.initialize,
                (
                    config.contributionToken,
                    config.feeClaimAddress,
                    config.daoMultisig,
                    config.takadaoOperator,
                    config.kycProvider,
                    config.pauseGuardian,
                    config.tokenAdmin,
                    config.tokenName,
                    config.tokenSymbol
                )
            )
        );

        // Deploy BenefitMultiplierConsumer
        BenefitMultiplierConsumer benefitMultiplierConsumer = new BenefitMultiplierConsumer(
            config.functionsRouter,
            config.donId,
            config.gasLimit,
            config.subscriptionId
        );

        // Set BenefitMultiplierConsumer as an oracle in TakasurePool
        TakasurePool(proxy).setNewBenefitMultiplierConsumer(address(benefitMultiplierConsumer));

        // Setting TakasurePool as a requester in BenefitMultiplierConsumer
        benefitMultiplierConsumer.setNewRequester(proxy);

        // Add new source code to BenefitMultiplierConsumer
        benefitMultiplierConsumer.setBMSourceRequestCode(bmFetchScript);

        vm.stopBroadcast();

        return (proxy);
    }
}
