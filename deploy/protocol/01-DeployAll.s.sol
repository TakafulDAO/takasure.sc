// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumer} from "contracts/chainlink/functions/BenefitMultiplierConsumer.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract DeployAll is Script, DeployConstants {
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
