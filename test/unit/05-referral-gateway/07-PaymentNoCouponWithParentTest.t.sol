// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ReferralGatewayNoCouponWithParentPaymentTest is Test {
    TestDeployProtocol deployer;
    ReferralGateway referralGateway;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address referralGatewayAddress;
    address takadao;
    address KYCProvider;
    address pauseGuardian;
    address parent = makeAddr("parent");
    address child = makeAddr("child");
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "The LifeDao";
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
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (, referralGatewayAddress, , , , , , , usdcAddress, , helperConfig) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        KYCProvider = config.kycProvider;
        pauseGuardian = config.pauseGuardian;

        // Assign implementations
        referralGateway = ReferralGateway(referralGatewayAddress);
        usdc = IUSDC(usdcAddress);

        // Give and approve USDC
        deal(address(usdc), parent, USDC_INITIAL_AMOUNT);
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);

        vm.prank(parent);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);
        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);

        vm.startPrank(takadao);
        referralGateway.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        referralGateway.setDaoName(tDaoName);
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

    //======== preJoinEnabled = true, referralDiscount = true, with parent, no coupon ========//
    function testPrepaymentCase13() public {
        // Already collected fees with the modifiers logic
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();

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

        (, , , uint256 discount) = referralGateway.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(collectedFees, 1_250_000);
        assertEq(totalCollectedFees, collectedFees + alreadyCollectedFees);
        assertEq(referralGateway.getParentRewardsByChild(parent, child), expectedParentReward);
        assertEq(expectedParentReward, 1_000_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = true, referralDiscount = false, with parent, no coupon ========//
    function testPrepaymentCase14() public {
        vm.prank(takadao);
        referralGateway.switchReferralDiscount();

        // Already collected fees with the modifiers logic
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();
        assertEq(alreadyCollectedFees, 2_500_000);

        uint256 expectedParentReward = 0;

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(parent, child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, parent, child, 0, false);

        (, , , uint256 discount) = referralGateway.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(collectedFees, 3_750_000);
        assertEq(totalCollectedFees, collectedFees + alreadyCollectedFees);
        assertEq(referralGateway.getParentRewardsByChild(parent, child), expectedParentReward);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = false, referralDiscount = true, with parent, no coupon ========//
    function testPrepaymentCase15() public {
        vm.prank(takadao);
        referralGateway.setPrejoinDiscount(false);

        // Already collected fees with the modifiers logic
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();

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

        (, , , uint256 discount) = referralGateway.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(collectedFees, 3_750_000);
        assertEq(totalCollectedFees, collectedFees + alreadyCollectedFees);
        assertEq(referralGateway.getParentRewardsByChild(parent, child), expectedParentReward);
        assertEq(expectedParentReward, 1_000_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = false, referralDiscount = false, with parent, no coupon ========//
    function testPrepaymentCase16() public {
        vm.startPrank(takadao);
        referralGateway.switchReferralDiscount();

        referralGateway.setPrejoinDiscount(false);
        vm.stopPrank();

        // Already collected fees with the modifiers logic
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();
        assertEq(alreadyCollectedFees, 2_500_000);

        uint256 expectedParentReward = 0;

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees - ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = 0;

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(parent, child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, parent, child, 0, false);

        (, , , uint256 discount) = referralGateway.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(collectedFees, 6_250_000);
        assertEq(totalCollectedFees, collectedFees + alreadyCollectedFees);
        assertEq(referralGateway.getParentRewardsByChild(parent, child), expectedParentReward);
        assertEq(discount, expectedDiscount);
    }
}
