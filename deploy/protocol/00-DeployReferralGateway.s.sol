// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {BenefitMultiplierConsumer} from "contracts/chainlink/functions/BenefitMultiplierConsumer.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract DeployReferralGateway is Script, DeployConstants {
    using stdJson for string;

    function run() external returns (address proxy) {
        uint256 chainId = block.chainid;
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(chainId);

        string memory bmFetchScriptRoot;

        if (chainId == ARB_MAINNET_CHAIN_ID) {
            bmFetchScriptRoot = MAINNET_SCRIPT_ROOT;
        } else if (chainId == ARB_SEPOLIA_CHAIN_ID) {
            bmFetchScriptRoot = TESTNET_SCRIPT_ROOT;
        } else {
            bmFetchScriptRoot = UAT_SCRIPT_ROOT;
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
