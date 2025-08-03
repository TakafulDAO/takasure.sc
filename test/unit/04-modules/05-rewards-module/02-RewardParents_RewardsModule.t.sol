// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {DeployReserve} from "test/utils/05-DeployReserve.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {KYCModule} from "contracts/modules/KYCModule.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {ReferralRewardsModule} from "contracts/modules/ReferralRewardsModule.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {AssociationMemberState, ModuleState} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract RewardParents_ReferralRewardsModule is Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    DeployReserve reserveDeployer;
    AddAddressesAndRoles addressesAndRoles;

    KYCModule kycModule;
    SubscriptionModule subscriptionModule;
    ReferralRewardsModule referralRewardsModule;
    AddressManager addressManager;
    ModuleManager moduleManager;
    TakasureReserve takasureReserve;

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

    uint256 expectedLayer1Reward = 1_000_000; // 25 * 4% = 1
    uint256 expectedLayer2Reward = 250_000; // 25 * 1% = 0.25
    uint256 expectedLayer3Reward = 87_500; // 25 * 0.35% = 0.0875
    uint256 expectedLayer4Reward = 43_750; // 25 * 0.175% = 0.04375

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        reserveDeployer = new DeployReserve();
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

        takasureReserve = reserveDeployer.run(config, addrMgr);

        addressManager = addrMgr;
        moduleManager = modMgr;
        takadao = operator;
        couponRedeemer = redeemer;
        kycProvider = kyc;
        usdc = IUSDC(config.contributionToken);

        deal(address(usdc), alice, 25e6);
        deal(address(usdc), bob, 2375e4);
        deal(address(usdc), charlie, 2375e4);
        deal(address(usdc), dave, 2375e4);
        deal(address(usdc), eve, 2375e4);
        deal(address(usdc), frank, 2375e4);

        vm.prank(alice);
        usdc.approve(address(subscriptionModule), 25e6);
        vm.prank(bob);
        usdc.approve(address(subscriptionModule), 2375e4);
        vm.prank(charlie);
        usdc.approve(address(subscriptionModule), 2375e4);
        vm.prank(dave);
        usdc.approve(address(subscriptionModule), 2375e4);
        vm.prank(eve);
        usdc.approve(address(subscriptionModule), 2375e4);
        vm.prank(frank);
        usdc.approve(address(subscriptionModule), 2375e4);

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

    function testRewardModule_transferReward() public {
        uint256 contractBalance = usdc.balanceOf(address(referralRewardsModule)); // (25*5%) * 6 = 7.5
        // Balances before rewards distribution
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(charlie), 0);
        assertEq(usdc.balanceOf(dave), 0);
        assertEq(usdc.balanceOf(eve), 0);
        assertEq(usdc.balanceOf(frank), 0);
        assertEq(contractBalance, 75e5);

        // Donate Alice disctribution
        _donate(alice);

        // Everything should be the same because Alice does not have parents
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(charlie), 0);
        assertEq(usdc.balanceOf(dave), 0);
        assertEq(usdc.balanceOf(eve), 0);
        assertEq(usdc.balanceOf(frank), 0);
        assertEq(usdc.balanceOf(address(referralRewardsModule)), contractBalance);

        // Donate Bob distribution
        _donate(bob);

        assertEq(usdc.balanceOf(alice), expectedLayer1Reward);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(charlie), 0);
        assertEq(usdc.balanceOf(dave), 0);
        assertEq(usdc.balanceOf(eve), 0);
        assertEq(usdc.balanceOf(frank), 0);
        assertEq(
            usdc.balanceOf(address(referralRewardsModule)),
            contractBalance - expectedLayer1Reward
        ); // 7.5 - 1 = 6.5

        // Donate Charlie distribution
        _donate(charlie);

        assertEq(usdc.balanceOf(alice), expectedLayer1Reward + expectedLayer2Reward);
        assertEq(usdc.balanceOf(bob), expectedLayer1Reward);
        assertEq(usdc.balanceOf(charlie), 0);
        assertEq(usdc.balanceOf(dave), 0);
        assertEq(usdc.balanceOf(eve), 0);
        assertEq(usdc.balanceOf(frank), 0);
        assertEq(
            usdc.balanceOf(address(referralRewardsModule)),
            contractBalance - (2 * expectedLayer1Reward) - expectedLayer2Reward
        ); // 7.5 - (2 * 1) - 0.25 = 7.5 - 2 - 0.25 = 5.25

        // Donate Dave distribution
        _donate(dave);

        assertEq(
            usdc.balanceOf(alice),
            expectedLayer1Reward + expectedLayer2Reward + expectedLayer3Reward
        );
        assertEq(usdc.balanceOf(bob), expectedLayer1Reward + expectedLayer2Reward);
        assertEq(usdc.balanceOf(charlie), expectedLayer1Reward);
        assertEq(usdc.balanceOf(dave), 0);
        assertEq(usdc.balanceOf(eve), 0);
        assertEq(usdc.balanceOf(frank), 0);
        assertEq(
            usdc.balanceOf(address(referralRewardsModule)),
            contractBalance -
                (3 * expectedLayer1Reward) -
                (2 * expectedLayer2Reward) -
                expectedLayer3Reward
        ); // 7.5 - (3 * 1) - (2 * 0.25) - 0.0875 = 7.5 - 3 - 0.5 - 0.0875 = 3.9125

        // Donate Eve distribution
        _donate(eve);

        assertEq(
            usdc.balanceOf(alice),
            expectedLayer1Reward +
                expectedLayer2Reward +
                expectedLayer3Reward +
                expectedLayer4Reward
        );
        assertEq(
            usdc.balanceOf(bob),
            expectedLayer1Reward + expectedLayer2Reward + expectedLayer3Reward
        );
        assertEq(usdc.balanceOf(charlie), expectedLayer1Reward + expectedLayer2Reward);
        assertEq(usdc.balanceOf(dave), expectedLayer1Reward);
        assertEq(usdc.balanceOf(eve), 0);
        assertEq(usdc.balanceOf(frank), 0);
        assertEq(
            usdc.balanceOf(address(referralRewardsModule)),
            contractBalance -
                (4 * expectedLayer1Reward) -
                (3 * expectedLayer2Reward) -
                (2 * expectedLayer3Reward) -
                expectedLayer4Reward
        ); // 7.5 - (4 * 1) - (3 * 0.25) - (2 * 0.0875) - 0.04375 = 7.5 - 4 - 0.75 - 0.175 - 0.04375 = 2.53125
        console2.log(
            "Contract Balance after rewards distribution: ",
            usdc.balanceOf(address(referralRewardsModule))
        ); // 2_531_250
        console2.log(
            expectedLayer1Reward +
                expectedLayer2Reward +
                expectedLayer3Reward +
                expectedLayer4Reward
        ); // 1_381_250

        // Operator will need to top up the needed amount
        // deal(
        //     address(usdc),
        //     takadao,
        //     expectedLayer4Reward +
        //         expectedLayer3Reward +
        //         expectedLayer2Reward +
        //         expectedLayer1Reward
        // );
        // vm.prank(takadao);
        // usdc.transfer(
        //     address(referralRewardsModule),
        //     expectedLayer4Reward +
        //         expectedLayer3Reward +
        //         expectedLayer2Reward +
        //         expectedLayer1Reward
        // );

        // Donate Frank distribution
        // _donate(frank);

        // assertEq(
        //     usdc.balanceOf(alice),
        //     expectedLayer1Reward +
        //         expectedLayer2Reward +
        //         expectedLayer3Reward +
        //         expectedLayer4Reward
        // );
        // assertEq(
        //     usdc.balanceOf(bob),
        //     expectedLayer1Reward +
        //         expectedLayer2Reward +
        //         expectedLayer3Reward +
        //         expectedLayer4Reward
        // );
        // assertEq(
        //     usdc.balanceOf(charlie),
        //     expectedLayer1Reward + expectedLayer2Reward + expectedLayer3Reward
        // );
        // assertEq(usdc.balanceOf(dave), expectedLayer1Reward + expectedLayer2Reward);
        // assertEq(usdc.balanceOf(eve), expectedLayer1Reward);
        // assertEq(usdc.balanceOf(frank), 0);
    }

    function _donate(address user) internal {
        vm.prank(takadao);
        subscriptionModule.transferSubscriptionToReserve(user);
    }
}
