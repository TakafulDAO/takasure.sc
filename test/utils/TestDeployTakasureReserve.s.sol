// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {TakasureReserve} from "contracts/takasure/core/TakasureReserve.sol";
import {JoinModule} from "contracts/takasure/modules/JoinModule.sol";
import {MembersModule} from "contracts/takasure/modules/MembersModule.sol";
import {RevenueModule} from "contracts/takasure/modules/RevenueModule.sol";
import {UserRouter} from "contracts/takasure/router/UserRouter.sol";
import {BenefitMultiplierConsumer} from "contracts/takasure/oracle/BenefitMultiplierConsumer.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";
import {TSToken} from "contracts/token/TSToken.sol";

contract TestDeployTakasureReserve is Script {
    BenefitMultiplierConsumer benefitMultiplierConsumer;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant MINTER_ADMIN_ROLE = keccak256("MINTER_ADMIN_ROLE");
    bytes32 public constant BURNER_ADMIN_ROLE = keccak256("BURNER_ADMIN_ROLE");

    address takasureReserveImplementation;
    address userRouterImplementation;

    string root;
    string scriptPath;

    function run()
        external
        returns (
            address takasureReserve,
            address joinModule,
            address membersModule,
            address revenueModule,
            address router,
            address contributionTokenAddress,
            HelperConfig helperConfig
        )
    {
        helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        root = vm.projectRoot();
        scriptPath = string.concat(root, "/scripts/chainlink-functions/bmFetchCode.js");
        string memory bmFetchScript = vm.readFile(scriptPath);

        vm.startBroadcast(msg.sender);

        // Deploy TakasureReserve
        takasureReserveImplementation = address(new TakasureReserve());
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
        benefitMultiplierConsumer = new BenefitMultiplierConsumer(
            config.functionsRouter,
            config.donId,
            config.gasLimit,
            config.subscriptionId
        );

        (joinModule, membersModule, revenueModule) = _deployModules(takasureReserve);

        // Deploy router
        userRouterImplementation = address(new UserRouter());
        router = UnsafeUpgrades.deployUUPSProxy(
            userRouterImplementation,
            abi.encodeCall(UserRouter.initialize, (takasureReserve, joinModule, membersModule))
        );

        _setContracts(
            benefitMultiplierConsumer,
            bmFetchScript,
            joinModule,
            membersModule,
            revenueModule,
            takasureReserve
        );

        TSToken creditToken = TSToken(TakasureReserve(takasureReserve).getReserveValues().daoToken);

        _assignRoles(takasureReserve, config.daoMultisig, creditToken, joinModule, membersModule);

        vm.stopBroadcast();

        contributionTokenAddress = TakasureReserve(takasureReserve)
            .getReserveValues()
            .contributionToken;

        return (
            takasureReserve,
            joinModule,
            membersModule,
            revenueModule,
            router,
            contributionTokenAddress,
            helperConfig
        );
    }

    function _deployModules(
        address _takasureReserve
    ) internal returns (address joinModule, address membersModule, address revenueModule) {
        // Deploy JoinModule
        address joinModuleImplementation = address(new JoinModule());
        joinModule = UnsafeUpgrades.deployUUPSProxy(
            joinModuleImplementation,
            abi.encodeCall(JoinModule.initialize, (_takasureReserve))
        );

        // Deploy MembersModule
        address membersModuleImplementation = address(new MembersModule());
        membersModule = UnsafeUpgrades.deployUUPSProxy(
            membersModuleImplementation,
            abi.encodeCall(MembersModule.initialize, (_takasureReserve))
        );

        // Deploy RevenueModule
        address revenueModuleImplementation = address(new RevenueModule());
        revenueModule = UnsafeUpgrades.deployUUPSProxy(
            revenueModuleImplementation,
            abi.encodeCall(RevenueModule.initialize, (_takasureReserve))
        );
    }

    function _setContracts(
        BenefitMultiplierConsumer _benefitMultiplierConsumer,
        string memory _bmFetchScript,
        address _joinModule,
        address _membersModule,
        address _revenueModule,
        address _takasureReserve
    ) internal {
        // Setting JoinModule as a requester in BenefitMultiplierConsumer
        _benefitMultiplierConsumer.setNewRequester(_joinModule);

        // Add new source code to BenefitMultiplierConsumer
        _benefitMultiplierConsumer.setBMSourceRequestCode(_bmFetchScript);

        // Set modules contracts in TakasureReserve
        TakasureReserve(_takasureReserve).setNewModuleContract(_joinModule);
        TakasureReserve(_takasureReserve).setNewModuleContract(_membersModule);
        TakasureReserve(_takasureReserve).setNewModuleContract(_revenueModule);
    }

    function _assignRoles(
        address _takasureReserve,
        address _daoMultisig,
        TSToken _creditToken,
        address _joinModule,
        address _membersModule
    ) internal {
        // After this set the dao multisig as the DEFAULT_ADMIN_ROLE in TakasureReserve
        TakasureReserve(_takasureReserve).grantRole(0x00, _daoMultisig);
        // And the modules as burner and minters
        _creditToken.grantRole(MINTER_ROLE, _joinModule);
        _creditToken.grantRole(MINTER_ROLE, _membersModule);
        _creditToken.grantRole(BURNER_ROLE, _joinModule);
        _creditToken.grantRole(BURNER_ROLE, _membersModule);

        // And renounce the DEFAULT_ADMIN_ROLE in TakasureReserve
        TakasureReserve(_takasureReserve).renounceRole(0x00, msg.sender);
        // And the burner and minter admins
        _creditToken.renounceRole(MINTER_ADMIN_ROLE, msg.sender);
        _creditToken.renounceRole(BURNER_ADMIN_ROLE, msg.sender);
    }
}
