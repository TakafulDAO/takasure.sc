// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
// import {BenefitModule} from "contracts/modules/BenefitModule.sol";
// import {KYCModule} from "contracts/modules/KYCModule.sol";
import {SubscriptionManagementModule} from "contracts/modules/SubscriptionManagementModule.sol";
import {ProtocolStorageModule} from "contracts/modules/ProtocolStorageModule.sol";
// import {ReferralRewardsModule} from "contracts/modules/ReferralRewardsModule.sol";
// import {RevenueModule} from "contracts/modules/RevenueModule.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ProtocolAddressType} from "contracts/types/TakasureTypes.sol";

contract DeployModules is Script {
    // address lifeBenefitModuleAddress;
    // address farewellBenefitModuleAddress;
    // address kycModuleImplementation;
    // address kycModuleAddress;
    address subscriptionManagementModuleImplementation;
    address subscriptionManagementModuleAddress;
    address protocolStorageImplementation;
    address protocolStorageAddress;
    // address referralRewardsModuleImplementation;
    // address referralRewardsModuleAddress;
    // address revenueModuleImplementation;
    // address revenueModuleAddress;
    address revShareModuleImplementation;
    address revShareModuleAddress;
    address subscriptionModuleImplementation;
    address subscriptionModuleAddress;

    function run(AddressManager addressManager)
        external
        returns (
            // BenefitModule lifeBenefitModule,
            // BenefitModule farewellBenefitModule,
            // KYCModule kycModule,
            SubscriptionManagementModule subscriptionManagementModule,
            ProtocolStorageModule protocolStorageModule,
            // ReferralRewardsModule referralRewardsModule,
            // RevenueModule revenueModule,
            RevShareModule revShareModule,
            SubscriptionModule subscriptionModule
        )
    {
        vm.startBroadcast(msg.sender);

        // Deploy KYCModule
        // kycModuleImplementation = address(new KYCModule());
        // kycModuleAddress = UnsafeUpgrades.deployUUPSProxy(
        //     kycModuleImplementation,
        //     abi.encodeCall(KYCModule.initialize, (address(addressManager), "MODULE__KYC"))
        // );

        // kycModule = KYCModule(kycModuleAddress);

        // addressManager.addProtocolAddress(
        //     "MODULE__KYC",
        //     kycModuleAddress,
        //     ProtocolAddressType.Module
        // );

        // Deploy SubscriptionManagementModule
        subscriptionManagementModuleImplementation = address(new SubscriptionManagementModule());
        subscriptionManagementModuleAddress = UnsafeUpgrades.deployUUPSProxy(
            subscriptionManagementModuleImplementation,
            abi.encodeCall(
                SubscriptionManagementModule.initialize, (address(addressManager), "MODULE__SUBSCRIPTION_MANAGEMENT")
            )
        );

        subscriptionManagementModule = SubscriptionManagementModule(subscriptionManagementModuleAddress);

        addressManager.addProtocolAddress(
            "MODULE__SUBSCRIPTION_MANAGEMENT", subscriptionManagementModuleAddress, ProtocolAddressType.Module
        );

        // Deploy ProtocolStorageModule
        protocolStorageImplementation = address(new ProtocolStorageModule());
        protocolStorageAddress = UnsafeUpgrades.deployUUPSProxy(
            protocolStorageImplementation,
            abi.encodeCall(ProtocolStorageModule.initialize, (address(addressManager), "MODULE__PROTOCOL_STORAGE"))
        );

        protocolStorageModule = ProtocolStorageModule(protocolStorageAddress);

        addressManager.addProtocolAddress(
            "MODULE__PROTOCOL_STORAGE", protocolStorageAddress, ProtocolAddressType.Module
        );

        // Deploy ReferralRewardsModule
        // referralRewardsModuleImplementation = address(new ReferralRewardsModule());
        // referralRewardsModuleAddress = UnsafeUpgrades.deployUUPSProxy(
        //     referralRewardsModuleImplementation,
        //     abi.encodeCall(
        //         ReferralRewardsModule.initialize,
        //         (address(addressManager), "MODULE__REFERRAL_REWARDS")
        //     )
        // );

        // referralRewardsModule = ReferralRewardsModule(referralRewardsModuleAddress);

        // addressManager.addProtocolAddress(
        //     "MODULE__REFERRAL_REWARDS",
        //     referralRewardsModuleAddress,
        //     ProtocolAddressType.Module
        // );

        // Deploy RevenueModule
        // revenueModuleImplementation = address(new RevenueModule());
        // revenueModuleAddress = UnsafeUpgrades.deployUUPSProxy(
        //     revenueModuleImplementation,
        //     abi.encodeCall(RevenueModule.initialize, (address(addressManager), "MODULE__REVENUE"))
        // );

        // revenueModule = RevenueModule(revenueModuleAddress);

        // addressManager.addProtocolAddress(
        //     "MODULE__REVENUE",
        //     revenueModuleAddress,
        //     ProtocolAddressType.Module
        // );

        // Deploy RevShareModule
        revShareModuleImplementation = address(new RevShareModule());
        revShareModuleAddress = UnsafeUpgrades.deployUUPSProxy(
            revShareModuleImplementation,
            abi.encodeCall(RevShareModule.initialize, (address(addressManager), "MODULE__REVSHARE"))
        );

        revShareModule = RevShareModule(revShareModuleAddress);

        addressManager.addProtocolAddress("MODULE__REVSHARE", revShareModuleAddress, ProtocolAddressType.Module);

        // Deploy SubscriptionModule
        subscriptionModuleImplementation = address(new SubscriptionModule());
        subscriptionModuleAddress = UnsafeUpgrades.deployUUPSProxy(
            subscriptionModuleImplementation,
            abi.encodeCall(SubscriptionModule.initialize, (address(addressManager), "MODULE__SUBSCRIPTION"))
        );

        subscriptionModule = SubscriptionModule(subscriptionModuleAddress);

        addressManager.addProtocolAddress("MODULE__SUBSCRIPTION", subscriptionModuleAddress, ProtocolAddressType.Module);

        vm.stopBroadcast();

        vm.startPrank(addressManager.owner());
        // Deploy LifeBenefitModule
        // lifeBenefitModuleAddress = addressManager.deployBenefitModule("LIFE_BENEFIT_MODULE");
        // lifeBenefitModule = BenefitModule(lifeBenefitModuleAddress);

        // // Deploy FarewellBenefitModule
        // farewellBenefitModuleAddress = addressManager.deployBenefitModule(
        //     "FAREWELL_BENEFIT_MODULE"
        // );
        // farewellBenefitModule = BenefitModule(farewellBenefitModuleAddress);

        vm.stopPrank();

        return (
            // lifeBenefitModule,
            // farewellBenefitModule,
            // kycModule,
            subscriptionManagementModule,
            protocolStorageModule,
            // referralRewardsModule,
            // revenueModule,
            revShareModule,
            subscriptionModule
        );
    }
    // To avoid this contract to be count in coverage
    function test() external {}
}
