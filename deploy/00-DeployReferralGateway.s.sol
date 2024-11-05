// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {BenefitMultiplierConsumer} from "contracts/takasure/oracle/BenefitMultiplierConsumer.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";

contract DeployReferralGateway is Script {
    using stdJson for string;

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

        BenefitMultiplierConsumer bmConsumer = new BenefitMultiplierConsumer(
            config.functionsRouter,
            config.donId,
            config.gasLimit,
            config.subscriptionId
        );

        // Add new source code to BenefitMultiplierConsumer
        bmConsumer.setBMSourceRequestCode(bmFetchScript);

        // Deploy TakasurePool
        proxy = Upgrades.deployUUPSProxy(
            "ReferralGateway.sol",
            abi.encodeCall(
                ReferralGateway.initialize,
                (
                    config.takadaoOperator,
                    config.kycProvider,
                    config.pauseGuardian,
                    config.contributionToken,
                    address(bmConsumer)
                )
            )
        );

        // Setting TakasurePool as a requester in BenefitMultiplierConsumer
        bmConsumer.setNewRequester(proxy);

        vm.stopBroadcast();

        return (proxy);
    }
}
