// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
// import {BenefitModule} from "contracts/modules/BenefitModule.sol";
// import {KYCModule} from "contracts/modules/KYCModule.sol";
// import {MemberModule} from "contracts/modules/MemberModule.sol";
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
    // address memberModuleImplementation;
    // address memberModuleAddress;
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
            // MemberModule memberModule,
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

        // Deploy MemberModule
        // memberModuleImplementation = address(new MemberModule());
        // memberModuleAddress = UnsafeUpgrades.deployUUPSProxy(
        //     memberModuleImplementation,
        //     abi.encodeCall(MemberModule.initialize, (address(addressManager), "MEMBER_MODULE"))
        // );

        // memberModule = MemberModule(memberModuleAddress);

        // addressManager.addProtocolAddress(
        //     "MEMBER_MODULE",
        //     memberModuleAddress,
        //     ProtocolAddressType.Module
        // );

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
            // memberModule,
            // referralRewardsModule,
            // revenueModule,
            revShareModule,
            subscriptionModule
        );
    }
    // To avoid this contract to be count in coverage
    function test() external {}
}
