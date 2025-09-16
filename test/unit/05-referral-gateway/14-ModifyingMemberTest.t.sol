// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ReferralGatewayModifyMemberTest is Test {
    TestDeployProtocol deployer;
    ReferralGateway referralGateway;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address referralGatewayAddress;
    address takadao;
    address kycProvider;
    address child = makeAddr("child");
    address parent = makeAddr("parent");
    address couponPool = makeAddr("couponPool");
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "The LifeDAO";
    uint256 public constant USDC_INITIAL_AMOUNT = 1000e6; // 1000 USDC
    uint256 public constant MAX_CONTRIBUTION = 250e6; // 250 USDC
    uint256 public constant MIN_CONTRIBUTION = 25e6; // 25 USDC
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee
    uint256 public constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution deducted from fee

    event OnCouponRedeemed(
        address indexed member,
        string indexed tDAOName,
        uint256 indexed couponAmount
    );

    function setUp() public {
        // Deployer
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (, referralGatewayAddress, , , , , , usdcAddress, , helperConfig) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        kycProvider = config.kycProvider;

        // Assign implementations
        referralGateway = ReferralGateway(address(referralGatewayAddress));
        usdc = IUSDC(usdcAddress);

        // Give USDC
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);
        deal(address(usdc), parent, USDC_INITIAL_AMOUNT);
        deal(address(usdc), couponPool, 1000e6);

        // USDC approvals
        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);
        vm.prank(parent);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);
        vm.prank(couponPool);
        usdc.approve(address(referralGateway), 1000e6);

        vm.prank(config.daoMultisig);
        referralGateway.createDAO(true, true, 1743479999, 1e12);

        vm.startPrank(takadao);
        referralGateway.setCouponPoolAddress(couponPool);
        referralGateway.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        vm.stopPrank();

        // The parent pays the full contribution without a coupon
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(MAX_CONTRIBUTION, address(0), parent, 0, false);

        // KYC the parent so he can refer the child and receive referral rewards
        vm.prank(kycProvider);
        referralGateway.approveKYC(parent);

        // The child pays the minimum contribution without a coupon, using the parent as a referrer, and donates the contribution
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(25e6, parent, child, 0, true);

        // KYC the child so the parent receive referral rewards
        vm.prank(kycProvider);
        referralGateway.approveKYC(child);
    }

    function testChildNowWantsThe25DollarPlanAfterThreeMonthsNoCoupons() public {
        vm.warp(block.timestamp + 90 days);
        vm.roll(block.number + 1);

        (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 fee,
            uint256 discount,
            bool isDonated
        ) = referralGateway.getPrepaidMember(child);

        assertEq(contributionBeforeFee, 25e6);
        assertEq(contributionAfterFee, 1825e4);
        assertEq(fee, 125e4);
        assertEq(discount, 375e4);
        assert(isDonated);

        // The child now wants to upgrade to the 50 USDC plan, so the new contribution is prorated
        // 25/12 = 2.0833$ per month -> for 9 months = 18.75$
        uint256 proRatedContribution = 18_750_000; // 18.75 USDC

        uint256 parentBalanceBefore = usdc.balanceOf(parent);

        vm.prank(couponRedeemer);
        (uint256 feeToOp, uint256 newDiscount) = referralGateway.modifyPrepaidMember(
            proRatedContribution,
            child,
            0 // no coupon
        );

        uint256 parentBalanceAfter = usdc.balanceOf(parent);

        // 18.75 - (18.75*0.1 + 18.75*0.05) = 15.9375
        uint256 expectedTransfer = proRatedContribution -
            (proRatedContribution * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100 -
            (proRatedContribution * REFERRAL_DISCOUNT_RATIO) /
            100;

        assertEq(expectedTransfer, 15_937_500);
        // The fee to operator should be fee-disount-referralReserve-repoolFee
        assertEq(feeToOp, 937_500);
        assertEq(newDiscount, 2_812_500); // 18.75 * 0.1 + 18.75 * 0.05 = 2.8125

        (contributionBeforeFee, contributionAfterFee, fee, discount, isDonated) = referralGateway
            .getPrepaidMember(child);

        assertEq(contributionBeforeFee, 43_750_000); // 25 + 18.75 = 43.75
        assert(!isDonated);

        assert(parentBalanceAfter > parentBalanceBefore);
    }

    function testChildNowWantsThe50DollarPlanAfterThreeMonthsNoCoupons() public {
        vm.warp(block.timestamp + 90 days);
        vm.roll(block.number + 1);

        (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 fee,
            uint256 discount,
            bool isDonated
        ) = referralGateway.getPrepaidMember(child);

        assertEq(contributionBeforeFee, 25e6);
        assertEq(contributionAfterFee, 1825e4);
        assertEq(fee, 125e4);
        assertEq(discount, 375e4);
        assert(isDonated);

        // The child now wants to upgrade to the 50 USDC plan, so the new contribution is prorated
        // 50/12 = 4.1667$ per month -> for 9 months = 37.5$
        uint256 proRatedContribution = 37_500_000; // 37.5 USDC

        uint256 parentBalanceBefore = usdc.balanceOf(parent);

        vm.prank(couponRedeemer);
        (uint256 feeToOp, uint256 newDiscount) = referralGateway.modifyPrepaidMember(
            proRatedContribution,
            child,
            0 // no coupon
        );

        uint256 parentBalanceAfter = usdc.balanceOf(parent);

        // 37.5 - (37.5*0.1 + 37.5*0.05) = 31.875
        uint256 expectedTransfer = proRatedContribution -
            (proRatedContribution * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100 -
            (proRatedContribution * REFERRAL_DISCOUNT_RATIO) /
            100;

        assertEq(expectedTransfer, 31_875_000);
        // The fee to operator should be fee-disount-referralReserve-repoolFee
        assertEq(feeToOp, 1_875_000);
        assertEq(newDiscount, 5_625_000); // 37.5 * 0.1 + 37.5 * 0.05 = 5.625

        (contributionBeforeFee, contributionAfterFee, fee, discount, isDonated) = referralGateway
            .getPrepaidMember(child);

        assertEq(contributionBeforeFee, 62_500_000); // 25 + 37.5 = 62.5
        assert(!isDonated);

        assert(parentBalanceAfter > parentBalanceBefore);
    }

    function testChildNowWantsThe250DollarPlanAfterThreeMonthsNoCoupons() public {
        vm.warp(block.timestamp + 90 days);
        vm.roll(block.number + 1);

        (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 fee,
            uint256 discount,
            bool isDonated
        ) = referralGateway.getPrepaidMember(child);

        assertEq(contributionBeforeFee, 25e6);
        assertEq(contributionAfterFee, 1825e4);
        assertEq(fee, 125e4);
        assertEq(discount, 375e4);
        assert(isDonated);

        // The child now wants to upgrade to the 250 USDC plan, so the new contribution is prorated
        // 250/12 = 20.833$ per month -> for 9 months = 187.5$
        uint256 proRatedContribution = 187_500_000; // 187.5 USDC

        uint256 parentBalanceBefore = usdc.balanceOf(parent);

        vm.prank(couponRedeemer);
        (uint256 feeToOp, uint256 newDiscount) = referralGateway.modifyPrepaidMember(
            proRatedContribution,
            child,
            0 // no coupon
        );

        uint256 parentBalanceAfter = usdc.balanceOf(parent);

        // 187.5 - (187.5*0.1 + 187.5*0.05) = 159.375
        uint256 expectedTransfer = proRatedContribution -
            (proRatedContribution * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100 -
            (proRatedContribution * REFERRAL_DISCOUNT_RATIO) /
            100;

        assertEq(expectedTransfer, 159_375_000);
        // The fee to operator should be fee-disount-referralReserve-repoolFee
        assertEq(feeToOp, 9_375_000);
        assertEq(newDiscount, 28_125_000); // 187.5 * 0.1 + 187.5 * 0.05 = 28.125

        (contributionBeforeFee, contributionAfterFee, fee, discount, isDonated) = referralGateway
            .getPrepaidMember(child);

        assertEq(contributionBeforeFee, 212_500_000); // 25 + 187.5 = 212.5
        assert(!isDonated);

        assert(parentBalanceAfter > parentBalanceBefore);
    }

    function testChildNowWantsThe50DollarPlanAfterThreeMonthsExtraCoupon() public {
        vm.warp(block.timestamp + 90 days);
        vm.roll(block.number + 1);

        (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 fee,
            uint256 discount,
            bool isDonated
        ) = referralGateway.getPrepaidMember(child);

        assertEq(contributionBeforeFee, 25e6);
        assertEq(contributionAfterFee, 1825e4);
        assertEq(fee, 125e4);
        assertEq(discount, 375e4);
        assert(isDonated);

        // The child now wants to upgrade to the 50 USDC plan, so the new contribution is prorated
        // 50/12 = 4.1667$ per month -> for 9 months = 37.5$
        uint256 proRatedContribution = 37_500_000; // 37.5 USDC

        uint256 parentBalanceBefore = usdc.balanceOf(parent);

        assertEq(referralGateway.donationsFromCoupons(), 0);

        vm.prank(couponRedeemer);
        (uint256 feeToOp, uint256 newDiscount) = referralGateway.modifyPrepaidMember(
            proRatedContribution,
            child,
            50e6 // 50 USDC coupon
        );

        uint256 parentBalanceAfter = usdc.balanceOf(parent);

        // 37.5 - (37.5*0.1 + 37.5*0.05) = 31.875
        uint256 expectedTransfer = proRatedContribution -
            (proRatedContribution * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100 -
            (proRatedContribution * REFERRAL_DISCOUNT_RATIO) /
            100;

        assertEq(expectedTransfer, 31_875_000);
        // The fee to operator should be fee-disount-referralReserve-repoolFee
        assertEq(feeToOp, 7_500_000);

        (contributionBeforeFee, contributionAfterFee, fee, , isDonated) = referralGateway
            .getPrepaidMember(child);

        assertEq(contributionBeforeFee, 62_500_000); // 25 + 37.5 = 62.5
        assertEq(newDiscount, 0);
        assert(!isDonated);

        assert(parentBalanceAfter > parentBalanceBefore);

        assertEq(referralGateway.donationsFromCoupons(), 50e6 - proRatedContribution);
    }
}
