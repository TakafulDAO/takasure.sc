// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {KYCModule} from "contracts/modules/KYCModule.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {ReferralRewardsModule} from "contracts/modules/ReferralRewardsModule.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {AssociationMemberState, ModuleState} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract CalculateRewards_ReferralRewardsModule is Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;

    KYCModule kycModule;
    SubscriptionModule subscriptionModule;
    ReferralRewardsModule referralRewardsModule;
    AddressManager addressManager;
    ModuleManager moduleManager;

    address takadao;
    address couponRedeemer;
    address kycProvider;
    IUSDC usdc;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address dave = makeAddr("dave");
    address eve = makeAddr("eve");
    address frank = makeAddr("frank");

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        addressesAndRoles = new AddAddressesAndRoles();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addrMgr,
            ModuleManager modMgr
        ) = managersDeployer.run();
        (address operator, , address kyc, address redeemer, , ) = addressesAndRoles.run(
            addrMgr,
            config,
            address(modMgr)
        );

        (, , kycModule, , referralRewardsModule, , subscriptionModule) = moduleDeployer.run(
            addrMgr
        );

        addressManager = addrMgr;
        moduleManager = modMgr;
        takadao = operator;
        couponRedeemer = redeemer;
        kycProvider = kyc;
        usdc = IUSDC(config.contributionToken);

        deal(address(usdc), alice, 25e6);
        deal(address(usdc), bob, 25e6);
        deal(address(usdc), charlie, 25e6);
        deal(address(usdc), dave, 25e6);
        deal(address(usdc), eve, 25e6);
        deal(address(usdc), frank, 25e6);

        vm.prank(alice);
        usdc.approve(address(subscriptionModule), 25e6);
        vm.prank(bob);
        usdc.approve(address(subscriptionModule), 25e6);
        vm.prank(charlie);
        usdc.approve(address(subscriptionModule), 25e6);
        vm.prank(dave);
        usdc.approve(address(subscriptionModule), 25e6);
        vm.prank(eve);
        usdc.approve(address(subscriptionModule), 25e6);
        vm.prank(frank);
        usdc.approve(address(subscriptionModule), 25e6);

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(alice, address(0), 0, block.timestamp);

        vm.prank(kycProvider);
        kycModule.approveKYC(alice);

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(bob, alice, 0, block.timestamp);

        vm.prank(kycProvider);
        kycModule.approveKYC(bob);

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(charlie, bob, 0, block.timestamp);

        vm.prank(kycProvider);
        kycModule.approveKYC(charlie);

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(dave, charlie, 0, block.timestamp);

        vm.prank(kycProvider);
        kycModule.approveKYC(dave);

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(eve, dave, 0, block.timestamp);

        vm.prank(kycProvider);
        kycModule.approveKYC(eve);

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(frank, eve, 0, block.timestamp);

        vm.prank(kycProvider);
        kycModule.approveKYC(frank);
    }

    function testRewardsModule_childToParent() public view {
        assertEq(referralRewardsModule.childToParent(alice), address(0));
        assertEq(referralRewardsModule.childToParent(bob), alice);
        assertEq(referralRewardsModule.childToParent(charlie), bob);
        assertEq(referralRewardsModule.childToParent(dave), charlie);
        assertEq(referralRewardsModule.childToParent(eve), dave);
        assertEq(referralRewardsModule.childToParent(frank), eve);
    }

    function testRewardsModule_parentRewardsByChild() public view {
        assertEq(referralRewardsModule.parentRewardsByChild(alice, address(0)), 0);
        uint256 expectedLayer1Reward = 1_000_000; // 25 * 4% = 1
        uint256 expectedLayer2Reward = 250_000; // 25 * 1% = 0.25
        uint256 expectedLayer3Reward = 87_500; // 25 * 0.35% = 0.0875
        uint256 expectedLayer4Reward = 43_750; // 25 * 0.175% = 0.04375

        // Layer 1
        assertEq(referralRewardsModule.parentRewardsByChild(alice, bob), expectedLayer1Reward);
        assertEq(referralRewardsModule.parentRewardsByChild(bob, charlie), expectedLayer1Reward);
        assertEq(referralRewardsModule.parentRewardsByChild(charlie, dave), expectedLayer1Reward);
        assertEq(referralRewardsModule.parentRewardsByChild(dave, eve), expectedLayer1Reward);
        assertEq(referralRewardsModule.parentRewardsByChild(eve, frank), expectedLayer1Reward);

        // Layer 2
        assertEq(referralRewardsModule.parentRewardsByChild(alice, charlie), expectedLayer2Reward);
        assertEq(referralRewardsModule.parentRewardsByChild(bob, dave), expectedLayer2Reward);
        assertEq(referralRewardsModule.parentRewardsByChild(charlie, eve), expectedLayer2Reward);
        assertEq(referralRewardsModule.parentRewardsByChild(dave, frank), expectedLayer2Reward);

        // Layer 3
        assertEq(referralRewardsModule.parentRewardsByChild(alice, dave), expectedLayer3Reward);
        assertEq(referralRewardsModule.parentRewardsByChild(bob, eve), expectedLayer3Reward);
        assertEq(referralRewardsModule.parentRewardsByChild(charlie, frank), expectedLayer3Reward);

        // Layer 4
        assertEq(referralRewardsModule.parentRewardsByChild(alice, eve), expectedLayer4Reward);
        assertEq(referralRewardsModule.parentRewardsByChild(bob, frank), expectedLayer4Reward);

        // No rewards for alice from frank
        assertEq(referralRewardsModule.parentRewardsByChild(alice, frank), 0);
    }

    function testRewardsModule_parentRewardsByLayer() public view {
        uint256 expectedLayer1Reward = 1_000_000; // 25 * 4% = 1
        uint256 expectedLayer2Reward = 250_000; // 25 * 1% = 0.25
        uint256 expectedLayer3Reward = 87_500; // 25 * 0.35% = 0.0875
        uint256 expectedLayer4Reward = 43_750; // 25 * 0.175% = 0.04375

        // Layer 1
        assertEq(referralRewardsModule.parentRewardsByLayer(alice, 1), expectedLayer1Reward);
        assertEq(referralRewardsModule.parentRewardsByLayer(bob, 1), expectedLayer1Reward);
        assertEq(referralRewardsModule.parentRewardsByLayer(charlie, 1), expectedLayer1Reward);
        assertEq(referralRewardsModule.parentRewardsByLayer(dave, 1), expectedLayer1Reward);
        assertEq(referralRewardsModule.parentRewardsByLayer(eve, 1), expectedLayer1Reward);

        // Layer 2
        assertEq(referralRewardsModule.parentRewardsByLayer(alice, 2), expectedLayer2Reward);
        assertEq(referralRewardsModule.parentRewardsByLayer(bob, 2), expectedLayer2Reward);
        assertEq(referralRewardsModule.parentRewardsByLayer(charlie, 2), expectedLayer2Reward);
        assertEq(referralRewardsModule.parentRewardsByLayer(dave, 2), expectedLayer2Reward);

        // Layer 3
        assertEq(referralRewardsModule.parentRewardsByLayer(alice, 3), expectedLayer3Reward);
        assertEq(referralRewardsModule.parentRewardsByLayer(bob, 3), expectedLayer3Reward);
        assertEq(referralRewardsModule.parentRewardsByLayer(charlie, 3), expectedLayer3Reward);

        // Layer 4
        assertEq(referralRewardsModule.parentRewardsByLayer(alice, 4), expectedLayer4Reward);
        assertEq(referralRewardsModule.parentRewardsByLayer(bob, 4), expectedLayer4Reward);
    }
}
