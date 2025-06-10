// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {TSToken} from "contracts/token/TSToken.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";
import {RevenueModule} from "contracts/modules/RevenueModule.sol";
import {BenefitMultiplierConsumer} from "contracts/helpers/chainlink/functions/BenefitMultiplierConsumer.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployTakasureReserve is Script {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant MINTER_ADMIN_ROLE = keccak256("MINTER_ADMIN_ROLE");
    bytes32 public constant BURNER_ADMIN_ROLE = keccak256("BURNER_ADMIN_ROLE");

    function run()
        external
        returns (
            address takasureReserve,
            address entryModule,
            address memberModule,
            address revenueModule
        )
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
            "TakasureReserve.sol",
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

        // Deploy EntryModule
        entryModule = Upgrades.deployUUPSProxy(
            "EntryModule.sol",
            abi.encodeCall(EntryModule.initialize, (takasureReserve))
        );

        // Deploy MemberModule
        memberModule = Upgrades.deployUUPSProxy(
            "MemberModule.sol",
            abi.encodeCall(MemberModule.initialize, (takasureReserve))
        );

        // Deploy RevemueModule
        revenueModule = Upgrades.deployUUPSProxy(
            "RevenueModule.sol",
            abi.encodeCall(RevenueModule.initialize, (takasureReserve))
        );

        // Set BenefitMultiplierConsumer as an oracle in TakasurePool
        TakasureReserve(takasureReserve).setNewBenefitMultiplierConsumerAddress(
            address(benefitMultiplierConsumer)
        );

        // Add new source code to BenefitMultiplierConsumer
        benefitMultiplierConsumer.setBMSourceRequestCode(bmFetchScript);

        // Setting EntryModule as a requester in BenefitMultiplierConsumer
        benefitMultiplierConsumer.setNewRequester(entryModule);

        // Set EntryModule as a module in TakasurePool
        // TakasureReserve(takasureReserve).setNewModuleContract(entryModule);

        // Set MemberModule as a module in TakasurePool
        // TakasureReserve(takasureReserve).setNewModuleContract(memberModule);

        // Set RevenueModule as a module in TakasurePool
        // TakasureReserve(takasureReserve).setNewModuleContract(revenueModule);

        TSToken creditToken = TSToken(TakasureReserve(takasureReserve).getReserveValues().daoToken);

        // After this set the dao multisig as the DEFAULT_ADMIN_ROLE in TakasureReserve
        TakasureReserve(takasureReserve).grantRole(0x00, config.daoMultisig);
        // And the modules as burner and minters
        creditToken.grantRole(MINTER_ROLE, entryModule);
        creditToken.grantRole(MINTER_ROLE, memberModule);
        creditToken.grantRole(BURNER_ROLE, entryModule);
        creditToken.grantRole(BURNER_ROLE, memberModule);

        // And renounce the DEFAULT_ADMIN_ROLE in TakasureReserve
        TakasureReserve(takasureReserve).renounceRole(0x00, msg.sender);
        // And the burner and minter admins
        creditToken.renounceRole(MINTER_ADMIN_ROLE, msg.sender);
        creditToken.renounceRole(BURNER_ADMIN_ROLE, msg.sender);

        vm.stopBroadcast();
    }
}
