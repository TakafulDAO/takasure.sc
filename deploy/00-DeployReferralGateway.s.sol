// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {BenefitMultiplierConsumer} from "contracts/takasure/oracle/BenefitMultiplierConsumer.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";

contract DeployReferralGateway is Script {
    function run() external returns (address proxy) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast();

        BenefitMultiplierConsumer bmConsumer = new BenefitMultiplierConsumer(
            config.functionsRouter,
            config.donId,
            config.gasLimit,
            config.subscriptionId
        );

        // Deploy TakasurePool
        proxy = Upgrades.deployUUPSProxy(
            "ReferralGateway.sol",
            abi.encodeCall(
                ReferralGateway.initialize,
                (
                    config.takadaoOperator,
                    config.kycProvider,
                    config.contributionToken,
                    address(bmConsumer)
                )
            )
        );

        vm.stopBroadcast();

        return (proxy);
    }
}
