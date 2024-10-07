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
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant MINTER_ADMIN_ROLE = keccak256("MINTER_ADMIN_ROLE");
    bytes32 public constant BURNER_ADMIN_ROLE = keccak256("BURNER_ADMIN_ROLE");

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

        // Deploy JoinModule
        joinModule = Upgrades.deployUUPSProxy(
            "JoinModule.sol",
            abi.encodeCall(JoinModule.initialize, (takasureReserve))
        );

        // Deploy MembersModule
        membersModule = Upgrades.deployUUPSProxy(
            "MembersModule.sol",
            abi.encodeCall(MembersModule.initialize, (takasureReserve))
        );

        // Set BenefitMultiplierConsumer as an oracle in TakasurePool
        TakasureReserve(takasureReserve).setNewBenefitMultiplierConsumerAddress(
            address(benefitMultiplierConsumer)
        );

        // Add new source code to BenefitMultiplierConsumer
        benefitMultiplierConsumer.setBMSourceRequestCode(bmFetchScript);

        // Setting JoinModule as a requester in BenefitMultiplierConsumer
        benefitMultiplierConsumer.setNewRequester(joinModule);

        // Set JoinModule as a module in TakasurePool
        TakasureReserve(takasureReserve).setNewJoinModuleContract(joinModule);

        // Set MembersModule as a module in TakasurePool
        TakasureReserve(takasureReserve).setNewMembersModuleContract(membersModule);

        TSTokenSize creditToken = TSTokenSize(
            TakasureReserve(takasureReserve).getReserveValues().daoToken
        );

        // After this set the dao multisig as the DEFAULT_ADMIN_ROLE in TakasureReserve
        TakasureReserve(takasureReserve).grantRole(0x00, config.daoMultisig);
        // And the modules as burner and minters
        creditToken.grantRole(MINTER_ROLE, joinModule);
        creditToken.grantRole(MINTER_ROLE, membersModule);
        creditToken.grantRole(BURNER_ROLE, joinModule);
        creditToken.grantRole(BURNER_ROLE, membersModule);

        // And renounce the DEFAULT_ADMIN_ROLE in TakasureReserve
        TakasureReserve(takasureReserve).renounceRole(0x00, msg.sender);
        // And the burner and minter admins
        creditToken.renounceRole(MINTER_ADMIN_ROLE, msg.sender);
        creditToken.renounceRole(BURNER_ADMIN_ROLE, msg.sender);

        vm.stopBroadcast();
    }
}
