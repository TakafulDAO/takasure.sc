// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {KYCModule} from "contracts/modules/KYCModule.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";
import {RevenueModule} from "contracts/modules/RevenueModule.sol";
import {UserRouter} from "contracts/router/UserRouter.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ProtocolAddressType} from "contracts/types/TakasureTypes.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract TestDeployProtocol is Script {
    ModuleManager moduleManager;
    AddressManager addressManager;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant MINTER_ADMIN_ROLE = keccak256("MINTER_ADMIN_ROLE");
    bytes32 public constant BURNER_ADMIN_ROLE = keccak256("BURNER_ADMIN_ROLE");
    bytes32 public constant ROUTER = keccak256("ROUTER");

    address takasureReserveImplementation;
    address userRouterImplementation;

    string root;
    string scriptPath;

    struct DeployModuleFunctionParams {
        address takasureReserve;
        address takadaoOperator;
        address kycProvider;
        address contributionToken;
        address couponPool;
        address pauseGuardian;
    }

    struct AssignRolesFunctionParams {
        address addressManager;
        address daoMultisig;
        address takadaoOperator;
        address kycProvider;
        address subscriptionModuleAddress;
        address kycModuleAddress;
        address memberModuleAddress;
    }

    function run()
        external
        returns (
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

        addressManager = new AddressManager();

        // Deploy TakasureReserve
        takasureReserveImplementation = address(new TakasureReserve());
        takasureReserve = UnsafeUpgrades.deployUUPSProxy(
            takasureReserveImplementation,
            abi.encodeCall(
                TakasureReserve.initialize,
                (config.contributionToken, address(addressManager))
            )
        );

        moduleManager = new ModuleManager(address(takasureReserve));

        addressManager.addProtocolAddress(
            "MODULE_MANAGER",
            address(moduleManager),
            ProtocolAddressType.Protocol
        );

        addressManager.addProtocolAddress(
            "FEE_CLAIM_ADDRESS",
            config.feeClaimAddress,
            ProtocolAddressType.Admin
        );

        (
            referralGatewayAddress,
            subscriptionModuleAddress,
            kycModuleAddress,
            memberModuleAddress,
            revenueModuleAddress
        ) = _deployModules(
            DeployModuleFunctionParams({
                takasureReserve: takasureReserve,
                takadaoOperator: config.takadaoOperator,
                kycProvider: config.kycProvider,
                contributionToken: config.contributionToken,
                couponPool: makeAddr("couponPool"),
                pauseGuardian: config.pauseGuardian
            })
        );

        addressManager.addProtocolAddress(
            "SUBSCRIPTION_MODULE",
            subscriptionModuleAddress,
            ProtocolAddressType.Module
        );

        addressManager.addProtocolAddress(
            "KYC_MODULE",
            kycModuleAddress,
            ProtocolAddressType.Module
        );

        addressManager.addProtocolAddress(
            "MEMBER_MODULE",
            memberModuleAddress,
            ProtocolAddressType.Module
        );

        addressManager.addProtocolAddress(
            "REVENUE_MODULE",
            revenueModuleAddress,
            ProtocolAddressType.Module
        );

        // Deploy router
        userRouterImplementation = address(new UserRouter());
        routerAddress = UnsafeUpgrades.deployUUPSProxy(
            userRouterImplementation,
            abi.encodeCall(UserRouter.initialize, (takasureReserve))
        );

        addressManager.addProtocolAddress("ROUTER", routerAddress, ProtocolAddressType.Protocol);

        _createRoles(address(addressManager));

        _assignRoles(
            AssignRolesFunctionParams({
                addressManager: address(addressManager),
                daoMultisig: config.daoMultisig,
                takadaoOperator: config.takadaoOperator,
                kycProvider: config.kycProvider,
                subscriptionModuleAddress: subscriptionModuleAddress,
                kycModuleAddress: kycModuleAddress,
                memberModuleAddress: memberModuleAddress
            })
        );

        vm.stopBroadcast();

        contributionTokenAddress = TakasureReserve(takasureReserve)
            .getReserveValues()
            .contributionToken;

        vm.prank(config.takadaoOperator);
        addressManager.acceptProposedRole(Roles.OPERATOR);

        vm.prank(config.daoMultisig);
        addressManager.acceptProposedRole(Roles.DAO_MULTISIG);

        vm.prank(config.kycProvider);
        addressManager.acceptProposedRole(Roles.KYC_PROVIDER);

        return (
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

    address referralGatewayImplementation;
    address subscriptionModuleImplementation;
    address kycModuleImplementation;
    address memberModuleImplementation;
    address revenueModuleImplementation;

    function _deployModules(
        DeployModuleFunctionParams memory _params
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
                (
                    _params.takadaoOperator,
                    _params.kycProvider,
                    _params.pauseGuardian,
                    _params.contributionToken
                )
            )
        );

        // Deploy SubscriptionModule
        subscriptionModuleImplementation = address(new SubscriptionModule());
        subscriptionModuleAddress_ = UnsafeUpgrades.deployUUPSProxy(
            subscriptionModuleImplementation,
            abi.encodeCall(
                SubscriptionModule.initialize,
                (_params.takasureReserve, referralGatewayAddress_, _params.couponPool)
            )
        );

        // Deploy KYCModule
        kycModuleImplementation = address(new KYCModule());
        kycModuleAddress_ = UnsafeUpgrades.deployUUPSProxy(
            kycModuleImplementation,
            abi.encodeCall(KYCModule.initialize, (_params.takasureReserve))
        );

        // Deploy MemberModule
        memberModuleImplementation = address(new MemberModule());
        memberModuleAddress_ = UnsafeUpgrades.deployUUPSProxy(
            memberModuleImplementation,
            abi.encodeCall(MemberModule.initialize, (_params.takasureReserve))
        );

        // Deploy RevenueModule
        revenueModuleImplementation = address(new RevenueModule());
        revenueModuleAddress_ = UnsafeUpgrades.deployUUPSProxy(
            revenueModuleImplementation,
            abi.encodeCall(RevenueModule.initialize, (_params.takasureReserve))
        );
    }

    function _createRoles(address _addressManager) internal {
        AddressManager(_addressManager).createNewRole(Roles.OPERATOR);
        AddressManager(_addressManager).createNewRole(Roles.DAO_MULTISIG);
        AddressManager(_addressManager).createNewRole(Roles.KYC_PROVIDER);
    }

    function _assignRoles(AssignRolesFunctionParams memory _params) internal {
        // Assign some global roles
        AddressManager(_params.addressManager).proposeRoleHolder(
            Roles.OPERATOR,
            _params.takadaoOperator
        );
        AddressManager(_params.addressManager).proposeRoleHolder(
            Roles.DAO_MULTISIG,
            _params.daoMultisig
        );
        AddressManager(_params.addressManager).proposeRoleHolder(
            Roles.KYC_PROVIDER,
            _params.kycProvider
        );
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
