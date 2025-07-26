// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {ReferralRewardsModule} from "contracts/modules/ReferralRewardsModule.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {AssociationMember, AssociationMemberState} from "contracts/types/TakasureTypes.sol";

contract Payment_SubscriptionModuleTest is StdCheats, Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    SubscriptionModule subscriptionModule;
    ReferralRewardsModule referralRewardsModule;
    address takadao;
    address couponRedeemer;
    address feeClaimAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    uint256 public constant USDC_INITIAL_AMOUNT = 150e6; // 150 USDC
    uint256 public constant SUBSCRIPTION = 25e6; // 25 USDC
    uint256 public constant FEE = 27; // 27% fee
    uint256 public constant REFERRAL_RESERVE = 5; // 5%

    event OnNewAssociationMember(
        uint256 indexed memberId,
        address indexed memberWallet,
        address indexed parentWallet
    );

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addressManager,
            ,
            address operator,
            ,
            ,
            address redeemer,
            address feeClaimer
        ) = managersDeployer.run();
        (, , , , referralRewardsModule, , subscriptionModule) = moduleDeployer.run(addressManager);

        // kycService = config.kycProvider;
        takadao = operator;
        couponRedeemer = redeemer;
        feeClaimAddress = feeClaimer;

        usdc = IUSDC(config.contributionToken);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);
        deal(address(usdc), bob, USDC_INITIAL_AMOUNT);

        vm.prank(alice);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);

        vm.prank(bob);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
    }

    function testSubscriptionModule_paySubscriptionOnBehalfOfCreatesANewAssociationMember() public {
        AssociationMember memory aliceAsMember = subscriptionModule.getAssociationMember(alice);

        assertEq(aliceAsMember.memberId, 0);
        assertEq(aliceAsMember.discount, 0);
        assertEq(aliceAsMember.associateStartTime, 0);
        assertEq(aliceAsMember.wallet, address(0));
        assertEq(aliceAsMember.parent, address(0));
        assert(aliceAsMember.memberState == AssociationMemberState.Inactive);
        assert(!aliceAsMember.isRefunded);
        assert(!aliceAsMember.isLifeProtected);
        assert(!aliceAsMember.isFarewellProtected);

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(alice, address(0), 0, block.timestamp);

        aliceAsMember = subscriptionModule.getAssociationMember(alice);

        assertEq(aliceAsMember.memberId, 1);
        assertEq(aliceAsMember.discount, 0);
        assertEq(aliceAsMember.associateStartTime, block.timestamp);
        assertEq(aliceAsMember.wallet, alice);
        assertEq(aliceAsMember.parent, address(0));
        assert(aliceAsMember.memberState == AssociationMemberState.Inactive);
        assert(!aliceAsMember.isRefunded);
        assert(!aliceAsMember.isLifeProtected);
        assert(!aliceAsMember.isFarewellProtected);
    }

    function testSubscriptionModule_paySubscriptionOnBehalfOfTransferTheCorrespondingAmounts()
        public
    {
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        uint256 feeClaimAddressBalanceBefore = usdc.balanceOf(feeClaimAddress);
        uint256 contractBalanceBefore = usdc.balanceOf(address(subscriptionModule));
        uint256 referralCotractBalanceBefore = usdc.balanceOf(address(referralRewardsModule));

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(alice, address(0), 0, block.timestamp);

        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        uint256 feeClaimAddressBalanceAfter = usdc.balanceOf(feeClaimAddress);
        uint256 contractBalanceAfter = usdc.balanceOf(address(subscriptionModule));
        uint256 referralCotractBalanceAfter = usdc.balanceOf(address(referralRewardsModule));

        assertEq(aliceBalanceAfter, aliceBalanceBefore - SUBSCRIPTION);
        assertEq(
            feeClaimAddressBalanceAfter,
            feeClaimAddressBalanceBefore + ((SUBSCRIPTION * (FEE - REFERRAL_RESERVE)) / 100)
        );
        assertEq(
            contractBalanceAfter,
            contractBalanceBefore + SUBSCRIPTION - (SUBSCRIPTION * FEE) / 100
        );
        assertEq(
            referralCotractBalanceAfter,
            referralCotractBalanceBefore + (SUBSCRIPTION * REFERRAL_RESERVE) / 100
        );
    }

    function testSubscriptionModule_paySubscriptionOnBehalfOfEmitsEvent() public {
        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(subscriptionModule));
        emit OnNewAssociationMember(1, alice, address(0));
        subscriptionModule.paySubscriptionOnBehalfOf(alice, address(0), 0, block.timestamp);
    }
}
