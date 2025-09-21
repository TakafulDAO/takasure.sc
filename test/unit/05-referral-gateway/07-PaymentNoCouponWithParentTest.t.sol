// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployReferralGateway} from "test/utils/00-DeployReferralGateway.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ReferralGatewayNoCouponWithParentPaymentTest is Test {
    DeployReferralGateway deployer;
    ReferralGateway referralGateway;
    IUSDC usdc;
    address takadao;
    address KYCProvider;
    address pauseGuardian;
    address parent = makeAddr("parent");
    address child = makeAddr("child");
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "The LifeDAO";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant LAYER_ONE_REWARD_RATIO = 4; // Layer one reward ratio 4%
    uint8 public constant SERVICE_FEE_RATIO = 27;
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee
    uint256 public constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution deducted from contribution
    uint256 public constant REFERRAL_RESERVE = 5; // 5% of contribution TO Referral Reserve
    uint256 public constant REPOOL_FEE_RATIO = 2; // 2% of contribution deducted from fee

    event OnPrepayment(
        address indexed parent,
        address indexed child,
        uint256 indexed contribution,
        uint256 fee,
        uint256 discount
    );

    function setUp() public {
        // Deployer
        deployer = new DeployReferralGateway();
        HelperConfig.NetworkConfig memory config;
        (config, referralGateway) = deployer.run();

        // Get config values
        takadao = config.takadaoOperator;
        KYCProvider = config.kycProvider;
        pauseGuardian = config.pauseGuardian;

        // Assign implementations
        usdc = IUSDC(config.contributionToken);

        // Give and approve USDC
        deal(address(usdc), parent, USDC_INITIAL_AMOUNT);
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);

        vm.prank(parent);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);
        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);

        vm.startPrank(takadao);
        referralGateway.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        referralGateway.createDAO(true, true, 1743479999, 1e12);
        vm.stopPrank();

        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            parent,
            0,
            false
        );

        vm.prank(KYCProvider);
        referralGateway.approveKYC(parent);
    }

    //======== preJoinEnabled = true, referralDiscount = true, rewardsEnabled = true, with parent, no coupon ========//
    function testPrepaymentCase25() public {
        // Already collected fees with the modifiers logic
        (, , , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(alreadyCollectedFees, 2_500_000);

        uint256 expectedParentReward = (CONTRIBUTION_AMOUNT * LAYER_ONE_REWARD_RATIO) / 100;

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REFERRAL_RESERVE) / 100) -
            ((CONTRIBUTION_AMOUNT * REFERRAL_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100) + ((CONTRIBUTION_AMOUNT * REFERRAL_DISCOUNT_RATIO) / 100);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(parent, child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, parent, child, 0, false);

        (, , , uint256 discount, ) = referralGateway.getPrepaidMember(child);

        (, , , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(collectedFees, 1_250_000);
        assertEq(totalCollectedFees, collectedFees + alreadyCollectedFees);
        assertEq(referralGateway.getParentRewardsByChild(parent, child), expectedParentReward);
        assertEq(expectedParentReward, 1_000_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = true, referralDiscount = true, rewardsEnabled = false, with parent, no coupon ========//
    function testPrepaymentCase26() public {
        vm.prank(takadao);
        referralGateway.switchRewardsDistribution();

        // Already collected fees with the modifiers logic
        (, , , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();
        assertEq(alreadyCollectedFees, 2_500_000);

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__IncompatibleSettings.selector);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, parent, child, 0, false);
    }

    //======== preJoinEnabled = true, referralDiscount = false, rewardsEnabled = true, with parent, no coupon ========//
    function testPrepaymentCase27() public {
        vm.prank(takadao);
        referralGateway.switchReferralDiscount();

        // Already collected fees with the modifiers logic
        (, , , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();
        assertEq(alreadyCollectedFees, 2_500_000);

        uint256 expectedParentReward = (CONTRIBUTION_AMOUNT * LAYER_ONE_REWARD_RATIO) / 100;

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REFERRAL_RESERVE) / 100) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(parent, child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, parent, child, 0, false);

        (, , , uint256 discount, ) = referralGateway.getPrepaidMember(child);

        (, , , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(collectedFees, 2_500_000);
        assertEq(totalCollectedFees, collectedFees + alreadyCollectedFees);
        assertEq(referralGateway.getParentRewardsByChild(parent, child), expectedParentReward);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = true, referralDiscount = false, rewardsEnabled = false, with parent, no coupon ========//
    function testPrepaymentCase28() public {
        vm.startPrank(takadao);
        referralGateway.switchReferralDiscount();
        referralGateway.switchRewardsDistribution();
        vm.stopPrank();

        // Already collected fees with the modifiers logic
        (, , , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();
        assertEq(alreadyCollectedFees, 2_500_000);

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__IncompatibleSettings.selector);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, parent, child, 0, false);
    }

    //======== preJoinEnabled = false, referralDiscount = true, rewardsEnabled = true, with parent, no coupon ========//
    function testPrepaymentCase29() public {
        vm.prank(takadao);
        referralGateway.switchPrejoinDiscount();

        // Already collected fees with the modifiers logic
        (, , , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(alreadyCollectedFees, 2_500_000);

        uint256 expectedParentReward = (CONTRIBUTION_AMOUNT * LAYER_ONE_REWARD_RATIO) / 100;

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * REFERRAL_RESERVE) / 100) -
            ((CONTRIBUTION_AMOUNT * REFERRAL_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = ((CONTRIBUTION_AMOUNT * REFERRAL_DISCOUNT_RATIO) / 100);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(parent, child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, parent, child, 0, false);

        (, , , uint256 discount, ) = referralGateway.getPrepaidMember(child);

        (, , , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(collectedFees, 3_750_000);
        assertEq(totalCollectedFees, collectedFees + alreadyCollectedFees);
        assertEq(referralGateway.getParentRewardsByChild(parent, child), expectedParentReward);
        assertEq(expectedParentReward, 1_000_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = false, referralDiscount = true, rewardsEnabled = false, with parent, no coupon ========//
    function testPrepaymentCase30() public {
        vm.startPrank(takadao);
        referralGateway.switchPrejoinDiscount();
        referralGateway.switchRewardsDistribution();
        vm.stopPrank();

        // Already collected fees with the modifiers logic
        (, , , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(alreadyCollectedFees, 2_500_000);

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__IncompatibleSettings.selector);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, parent, child, 0, false);
    }

    //======== preJoinEnabled = false, referralDiscount = false, rewardsEnabled = true, with parent, no coupon ========//
    function testPrepaymentCase31() public {
        vm.startPrank(takadao);
        referralGateway.switchPrejoinDiscount();
        referralGateway.switchReferralDiscount();
        vm.stopPrank();

        // Already collected fees with the modifiers logic
        (, , , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(alreadyCollectedFees, 2_500_000);

        uint256 expectedParentReward = (CONTRIBUTION_AMOUNT * LAYER_ONE_REWARD_RATIO) / 100;

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * REFERRAL_RESERVE) / 100) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = 0;

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(parent, child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, parent, child, 0, false);

        (, , , uint256 discount, ) = referralGateway.getPrepaidMember(child);

        (, , , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(collectedFees, 5_000_000);
        assertEq(totalCollectedFees, collectedFees + alreadyCollectedFees);
        assertEq(referralGateway.getParentRewardsByChild(parent, child), expectedParentReward);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = false, referralDiscount = false, rewardsEnabled = true, with parent, no coupon ========//
    function testPrepaymentCase32() public {
        vm.startPrank(takadao);
        referralGateway.switchReferralDiscount();
        referralGateway.switchPrejoinDiscount();
        referralGateway.switchRewardsDistribution();
        vm.stopPrank();

        // Already collected fees with the modifiers logic
        (, , , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();
        assertEq(alreadyCollectedFees, 2_500_000);

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__IncompatibleSettings.selector);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, parent, child, 0, false);
    }
}
