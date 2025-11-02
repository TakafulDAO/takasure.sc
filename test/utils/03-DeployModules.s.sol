// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
// import {BenefitModule} from "contracts/modules/BenefitModule.sol";
// import {KYCModule} from "contracts/modules/KYCModule.sol";
import {ManageSubscriptionModule} from "contracts/modules/ManageSubscriptionModule.sol";
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
    address manageSubscriptionModuleImplementation;
    address manageSubscriptionModuleAddress;
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

    function run(
        AddressManager addressManager
    )
        external
        returns (
            // BenefitModule lifeBenefitModule,
            // BenefitModule farewellBenefitModule,
            // KYCModule kycModule,
            ManageSubscriptionModule manageSubscriptionModule,
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
        //     abi.encodeCall(KYCModule.initialize, (address(addressManager), "KYC_MODULE"))
        // );

        // kycModule = KYCModule(kycModuleAddress);

        // addressManager.addProtocolAddress(
        //     "KYC_MODULE",
        //     kycModuleAddress,
        //     ProtocolAddressType.Module
        // );

        // Deploy ManageSubscriptionModule
        manageSubscriptionModuleImplementation = address(new ManageSubscriptionModule());
        manageSubscriptionModuleAddress = UnsafeUpgrades.deployUUPSProxy(
            manageSubscriptionModuleImplementation,
            abi.encodeCall(
                ManageSubscriptionModule.initialize,
                (address(addressManager), "MANAGE_SUBSCRIPTION_MODULE")
            )
        );

        manageSubscriptionModule = ManageSubscriptionModule(manageSubscriptionModuleAddress);

        addressManager.addProtocolAddress(
            "MANAGE_SUBSCRIPTION_MODULE",
            manageSubscriptionModuleAddress,
            ProtocolAddressType.Module
        );

        // Deploy ProtocolStorageModule
        protocolStorageImplementation = address(new ProtocolStorageModule());
        protocolStorageAddress = UnsafeUpgrades.deployUUPSProxy(
            protocolStorageImplementation,
            abi.encodeCall(
                ProtocolStorageModule.initialize,
                (address(addressManager), "PROTOCOL_STORAGE_MODULE")
            )
        );

        protocolStorageModule = ProtocolStorageModule(protocolStorageAddress);

        addressManager.addProtocolAddress(
            "PROTOCOL_STORAGE_MODULE",
            protocolStorageAddress,
            ProtocolAddressType.Module
        );

        // Deploy ReferralRewardsModule
        // referralRewardsModuleImplementation = address(new ReferralRewardsModule());
        // referralRewardsModuleAddress = UnsafeUpgrades.deployUUPSProxy(
        //     referralRewardsModuleImplementation,
        //     abi.encodeCall(
        //         ReferralRewardsModule.initialize,
        //         (address(addressManager), "REFERRAL_REWARDS_MODULE")
        //     )
        // );

        // referralRewardsModule = ReferralRewardsModule(referralRewardsModuleAddress);

        // addressManager.addProtocolAddress(
        //     "REFERRAL_REWARDS_MODULE",
        //     referralRewardsModuleAddress,
        //     ProtocolAddressType.Module
        // );

        // Deploy RevenueModule
        // revenueModuleImplementation = address(new RevenueModule());
        // revenueModuleAddress = UnsafeUpgrades.deployUUPSProxy(
        //     revenueModuleImplementation,
        //     abi.encodeCall(RevenueModule.initialize, (address(addressManager), "REVENUE_MODULE"))
        // );

        // revenueModule = RevenueModule(revenueModuleAddress);

        // addressManager.addProtocolAddress(
        //     "REVENUE_MODULE",
        //     revenueModuleAddress,
        //     ProtocolAddressType.Module
        // );

        // Deploy RevShareModule
        revShareModuleImplementation = address(new RevShareModule());
        revShareModuleAddress = UnsafeUpgrades.deployUUPSProxy(
            revShareModuleImplementation,
            abi.encodeCall(RevShareModule.initialize, (address(addressManager), "REVSHARE_MODULE"))
        );

        revShareModule = RevShareModule(revShareModuleAddress);

        addressManager.addProtocolAddress(
            "REVSHARE_MODULE",
            revShareModuleAddress,
            ProtocolAddressType.Module
        );

        // Deploy SubscriptionModule
        subscriptionModuleImplementation = address(new SubscriptionModule());
        subscriptionModuleAddress = UnsafeUpgrades.deployUUPSProxy(
            subscriptionModuleImplementation,
            abi.encodeCall(
                SubscriptionModule.initialize,
                (address(addressManager), "SUBSCRIPTION_MODULE")
            )
        );

        subscriptionModule = SubscriptionModule(subscriptionModuleAddress);

        addressManager.addProtocolAddress(
            "SUBSCRIPTION_MODULE",
            subscriptionModuleAddress,
            ProtocolAddressType.Module
        );

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
            manageSubscriptionModule,
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
