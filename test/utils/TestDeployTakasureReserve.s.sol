// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {TakasureReserve} from "contracts/takasure/core/TakasureReserve.sol";
import {JoinModule} from "contracts/takasure/modules/JoinModule.sol";
import {MembersModule} from "contracts/takasure/modules/MembersModule.sol";
import {BenefitMultiplierConsumer} from "contracts/takasure/oracle/BenefitMultiplierConsumer.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";

contract DeployTakasureReserve is Script {
    function run()
        external
        returns (
            address takasureReserve,
            address joinModule,
            address membersModule,
            address contributionTokenAddress,
            HelperConfig helperConfig
        )
    {
        helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        string memory root = vm.projectRoot();
        string memory scriptPath = string.concat(
            root,
            "/scripts/chainlink-functions/bmFetchCode.js"
        );
        string memory bmFetchScript = vm.readFile(scriptPath);

        vm.startBroadcast();

        // Deploy TakasureReserve
        address takasureReserveImplementation = address(new TakasureReserve());
        takasureReserve = UnsafeUpgrades.deployUUPSProxy(
            takasureReserveImplementation,
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

        // Setting TakasurePool as a requester in BenefitMultiplierConsumer
        benefitMultiplierConsumer.setNewRequester(takasureReserve);

        // Add new source code to BenefitMultiplierConsumer
        benefitMultiplierConsumer.setBMSourceRequestCode(bmFetchScript);

        // Deploy JoinModule
        address joinModuleImplementation = address(new JoinModule());
        joinModule = UnsafeUpgrades.deployUUPSProxy(
            joinModuleImplementation,
            abi.encodeCall(JoinModule.initialize, (takasureReserve))
        );

        // Deploy MembersModule
        address membersModuleImplementation = address(new MembersModule());
        membersModule = UnsafeUpgrades.deployUUPSProxy(
            membersModuleImplementation,
            abi.encodeCall(MembersModule.initialize, (takasureReserve))
        );

        vm.stopBroadcast();

        contributionTokenAddress = TakasureReserve(takasureReserve)
            .getReserveValues()
            .contributionToken;

        return (takasureReserve, joinModule, membersModule, contributionTokenAddress, helperConfig);
    }

    function assignAddresses(
        address takadao,
        address takasureReserve,
        address joinModule,
        address membersModule
    ) external {
        vm.startPrank(takadao);
        // Set JoinModule as a module in TakasurePool
        TakasureReserve(takasureReserve).setNewJoinModuleContract(joinModule);
        // Set MembersModule as a module in TakasurePool
        TakasureReserve(takasureReserve).setNewMembersModuleContract(membersModule);
        vm.stopPrank();
    }
}
