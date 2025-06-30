// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {ModuleManager} from "contracts/modules/manager/ModuleManager.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {KYCModule} from "contracts/modules/KYCModule.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";
import {RevenueModule} from "contracts/modules/RevenueModule.sol";
import {UserRouter} from "contracts/router/UserRouter.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {TSToken} from "contracts/token/TSToken.sol";
import {ModuleState} from "contracts/types/TakasureTypes.sol";

contract TestDeployProtocol is Script {
    BenefitMultiplierConsumerMock bmConsumerMock;
    ModuleManager moduleManager;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant MINTER_ADMIN_ROLE = keccak256("MINTER_ADMIN_ROLE");
    bytes32 public constant BURNER_ADMIN_ROLE = keccak256("BURNER_ADMIN_ROLE");
    bytes32 public constant MODULE_MANAGER = keccak256("MODULE_MANAGER");
    bytes32 public constant ROUTER = keccak256("ROUTER");

    address takasureReserveImplementation;
    address userRouterImplementation;

    string root;
    string scriptPath;

    function run()
        external
        returns (
            address tsToken,
            BenefitMultiplierConsumerMock,
            address takasureReserve,
            address referralGatewayAddress,
            address subscriptionModuleAddress,
            address kycModuleAddress,
            address memberModuleAddress,
            address revenueModuleAddress,
            address routerAddress,
            address contributionTokenAddress,
            address kycProvider,
            HelperConfig helperConfig
        )
    {
        helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast(msg.sender);

        // Deploy the BenefitMultiplierConsumerMock
        bmConsumerMock = _deployBMConsumer(
            config.functionsRouter,
            config.donId,
            config.gasLimit,
            config.subscriptionId
        );

        moduleManager = new ModuleManager();

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
                    address(moduleManager),
                    config.tokenName,
                    config.tokenSymbol
                )
            )
        );

        (
            referralGatewayAddress,
            subscriptionModuleAddress,
            kycModuleAddress,
            memberModuleAddress,
            revenueModuleAddress
        ) = _deployModules(
            takasureReserve,
            config.takadaoOperator,
            config.kycProvider,
            config.contributionToken,
            address(bmConsumerMock),
            makeAddr("ccipReceiverContract"),
            makeAddr("couponPool"),
            config.pauseGuardian
        );

        // Deploy router
        userRouterImplementation = address(new UserRouter());
        routerAddress = UnsafeUpgrades.deployUUPSProxy(
            userRouterImplementation,
            abi.encodeCall(
                UserRouter.initialize,
                (takasureReserve, subscriptionModuleAddress, memberModuleAddress)
            )
        );

        _setContracts(
            subscriptionModuleAddress,
            kycModuleAddress,
            memberModuleAddress,
            revenueModuleAddress
        );

        TSToken creditToken = TSToken(TakasureReserve(takasureReserve).getReserveValues().daoToken);
        tsToken = address(creditToken);

        _assignRoles(
            takasureReserve,
            config.daoMultisig,
            creditToken,
            subscriptionModuleAddress,
            kycModuleAddress,
            memberModuleAddress
        );

        vm.stopBroadcast();

        contributionTokenAddress = TakasureReserve(takasureReserve)
            .getReserveValues()
            .contributionToken;

        vm.startPrank(config.takadaoOperator);
        SubscriptionModule(subscriptionModuleAddress).grantRole(ROUTER, routerAddress);
        MemberModule(memberModuleAddress).grantRole(ROUTER, routerAddress);
        vm.stopPrank();

        return (
            tsToken,
            bmConsumerMock,
            takasureReserve,
            referralGatewayAddress,
            subscriptionModuleAddress,
            kycModuleAddress,
            memberModuleAddress,
            revenueModuleAddress,
            routerAddress,
            contributionTokenAddress,
            kycProvider,
            helperConfig
        );
    }

    function _deployBMConsumer(
        address _functionsRouter,
        bytes32 _donId,
        uint32 _gasLimit,
        uint64 _subscriptionId
    ) internal returns (BenefitMultiplierConsumerMock bmConsumerMock_) {
        bmConsumerMock_ = new BenefitMultiplierConsumerMock(
            _functionsRouter,
            _donId,
            _gasLimit,
            _subscriptionId
        );
    }

    address referralGatewayImplementation;
    address subscriptionModuleImplementation;
    address kycModuleImplementation;
    address memberModuleImplementation;
    address revenueModuleImplementation;

    function _deployModules(
        address _takasureReserve,
        address _takadaoOperator,
        address _kycProvider,
        address _contributionToken,
        address _bmConsumerMock,
        address _ccipReceiver,
        address _couponPool,
        address _pauseGuardian
    )
        internal
        returns (
            address referralGatewayAddress_,
            address subscriptionModuleAddress_,
            address kycModuleAddress_,
            address memberModuleAddress_,
            address revenueModuleAddress_
        )
    {
        // Deploy ReferralGateway
        referralGatewayImplementation = address(new ReferralGateway());

        referralGatewayAddress_ = UnsafeUpgrades.deployUUPSProxy(
            referralGatewayImplementation,
            abi.encodeCall(
                ReferralGateway.initialize,
                (_takadaoOperator, _kycProvider, _pauseGuardian, _contributionToken)
            )
        );

        // Deploy SubscriptionModule
        subscriptionModuleImplementation = address(new SubscriptionModule());
        subscriptionModuleAddress_ = UnsafeUpgrades.deployUUPSProxy(
            subscriptionModuleImplementation,
            abi.encodeCall(
                SubscriptionModule.initialize,
                (_takasureReserve, referralGatewayAddress_, _ccipReceiver, _couponPool)
            )
        );

        // Deploy KYCModule
        kycModuleImplementation = address(new KYCModule());
        kycModuleAddress_ = UnsafeUpgrades.deployUUPSProxy(
            kycModuleImplementation,
            abi.encodeCall(KYCModule.initialize, (_takasureReserve, subscriptionModuleAddress_))
        );

        // Deploy MemberModule
        memberModuleImplementation = address(new MemberModule());
        memberModuleAddress_ = UnsafeUpgrades.deployUUPSProxy(
            memberModuleImplementation,
            abi.encodeCall(MemberModule.initialize, (_takasureReserve))
        );

        // Deploy RevenueModule
        revenueModuleImplementation = address(new RevenueModule());
        revenueModuleAddress_ = UnsafeUpgrades.deployUUPSProxy(
            revenueModuleImplementation,
            abi.encodeCall(RevenueModule.initialize, (_takasureReserve))
        );
    }

    function _setContracts(
        address _subscriptionModuleAddress,
        address _kycModuleAddress,
        address _memberModuleAddress,
        address _revenueModuleAddress
    ) internal {
        bmConsumerMock.setNewRequester(_subscriptionModuleAddress);
        bmConsumerMock.setNewRequester(_kycModuleAddress);

        // Set modules contracts in TakasureReserve
        moduleManager.addModule(_subscriptionModuleAddress);
        moduleManager.addModule(_kycModuleAddress);
        moduleManager.addModule(_memberModuleAddress);
        moduleManager.addModule(_revenueModuleAddress);
    }

    function _assignRoles(
        address _takasureReserve,
        address _daoMultisig,
        TSToken _creditToken,
        address _subscriptionModuleAddress,
        address _kycModuleAddress,
        address _memberModuleAddress
    ) internal {
        // After this set the dao multisig as the DEFAULT_ADMIN_ROLE in TakasureReserve
        TakasureReserve(_takasureReserve).grantRole(0x00, _daoMultisig);
        // And the modules as burner and minters
        _creditToken.grantRole(MINTER_ROLE, _subscriptionModuleAddress);
        _creditToken.grantRole(MINTER_ROLE, _kycModuleAddress);
        _creditToken.grantRole(MINTER_ROLE, _memberModuleAddress);
        _creditToken.grantRole(BURNER_ROLE, _subscriptionModuleAddress);
        _creditToken.grantRole(BURNER_ROLE, _kycModuleAddress);
        _creditToken.grantRole(BURNER_ROLE, _memberModuleAddress);

        // And renounce the DEFAULT_ADMIN_ROLE in TakasureReserve
        TakasureReserve(_takasureReserve).renounceRole(0x00, msg.sender);
        // And the burner and minter admins
        _creditToken.renounceRole(MINTER_ADMIN_ROLE, msg.sender);
        _creditToken.renounceRole(BURNER_ADMIN_ROLE, msg.sender);
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
