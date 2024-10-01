// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {TakasureReserve} from "contracts/takasure/core/TakasureReserve.sol";
import {JoinModule} from "contracts/takasure/modules/JoinModule.sol";
import {MembersModule} from "contracts/takasure/modules/MembersModule.sol";
import {BenefitMultiplierConsumer} from "contracts/takasure/oracle/BenefitMultiplierConsumer.sol";
import {HelperConfig} from "../HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";

contract DeployTakasureReserve is Script {
    function run()
        external
        returns (address takasureReserve, address joinModule, address membersModule)
    {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        string memory root = vm.projectRoot();
        string memory scriptPath = string.concat(
            root,
            "/scripts/chainlink-functions/bmFetchCode.js"
        );
        string memory bmFetchScript = vm.readFile(scriptPath);

        vm.startBroadcast();

        // Deploy TakasureReserve
        takasureReserve = Upgrades.deployUUPSProxy(
            "TakasurePool.sol",
            abi.encodeCall(
                TakasureReserve.initialize,
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
        TakasureReserve(takasureReserve).setNewBenefitMultiplierConsumerAddress(
            address(benefitMultiplierConsumer)
        );

        // Setting TakasurePool as a requester in BenefitMultiplierConsumer
        benefitMultiplierConsumer.setNewRequester(takasureReserve);

        // Add new source code to BenefitMultiplierConsumer
        benefitMultiplierConsumer.setBMSourceRequestCode(bmFetchScript);

        // Deploy JoinModule
        joinModule = Upgrades.deployUUPSProxy(
            "JoinModule.sol",
            abi.encodeCall(JoinModule.initialize, (takasureReserve))
        );

        // Set JoinModule as a module in TakasurePool
        TakasureReserve(takasureReserve).setNewJoinModuleContract(joinModule);

        // Deploy MembersModule
        membersModule = Upgrades.deployUUPSProxy(
            "MembersModule.sol",
            abi.encodeCall(MembersModule.initialize, (takasureReserve))
        );

        // Set MembersModule as a module in TakasurePool
        TakasureReserve(takasureReserve).setNewMembersModuleContract(membersModule);

        vm.stopBroadcast();
    }
}
