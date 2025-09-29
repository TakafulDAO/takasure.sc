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
    uint256 initialContributionTimestamp;
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

        initialContributionTimestamp = block.timestamp;

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
        uint256 newContribution = 25e6;

        uint256 parentBalanceBefore = usdc.balanceOf(parent);

        vm.prank(couponRedeemer);
        (uint256 feeToOp, uint256 newDiscount) = referralGateway.lateContribution(
            newContribution,
            child,
            0, // no coupon
            initialContributionTimestamp
        );

        uint256 parentBalanceAfter = usdc.balanceOf(parent);

        uint256 expectedTransfer = ((newContribution * (360 - 90)) / 360) -
            (newContribution * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100 -
            (newContribution * REFERRAL_DISCOUNT_RATIO) /
            100;

        assertEq(expectedTransfer, 15_000_000);
        assertEq(feeToOp, 1_246_529);
        assertEq(newDiscount, 3_739_582);

        (contributionBeforeFee, contributionAfterFee, fee, discount, isDonated) = referralGateway
            .getPrepaidMember(child);

        assertEq(contributionBeforeFee, 25e6); // new plan
        assertEq(contributionAfterFee, 18_250_000);
        assertEq(fee, 2_496_529); // previous one + new one
        assertEq(discount, 7_489_582);
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
        uint256 newContribution = 50e6; // 50 USDC

        uint256 parentBalanceBefore = usdc.balanceOf(parent);

        vm.prank(couponRedeemer);
        (uint256 feeToOp, uint256 newDiscount) = referralGateway.lateContribution(
            newContribution,
            child,
            0, // no coupon
            initialContributionTimestamp
        );

        uint256 parentBalanceAfter = usdc.balanceOf(parent);

        uint256 expectedTransfer = ((newContribution * (360 - 90)) / 360) -
            (newContribution * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100 -
            (newContribution * REFERRAL_DISCOUNT_RATIO) /
            100;

        assertEq(expectedTransfer, 30_000_000);
        assertEq(feeToOp, 2_493_056);
        assertEq(newDiscount, 7_479_166);

        (contributionBeforeFee, contributionAfterFee, fee, discount, isDonated) = referralGateway
            .getPrepaidMember(child);

        assertEq(contributionBeforeFee, 50e6); // new plan
        assertEq(contributionAfterFee, 36_500_000);
        assertEq(fee, 3_743_056); // previous one + new one
        assertEq(discount, 11229166);
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
        uint256 newContribution = 250e6;

        uint256 parentBalanceBefore = usdc.balanceOf(parent);

        vm.prank(couponRedeemer);
        (uint256 feeToOp, uint256 newDiscount) = referralGateway.lateContribution(
            newContribution,
            child,
            0, // no coupon
            initialContributionTimestamp
        );

        uint256 parentBalanceAfter = usdc.balanceOf(parent);

        uint256 expectedTransfer = ((newContribution * (360 - 90)) / 360) -
            (newContribution * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100 -
            (newContribution * REFERRAL_DISCOUNT_RATIO) /
            100;

        assertEq(expectedTransfer, 150_000_000);
        assertEq(feeToOp, 12_465_279);
        assertEq(newDiscount, 37_395_832);

        (contributionBeforeFee, contributionAfterFee, fee, discount, isDonated) = referralGateway
            .getPrepaidMember(child);

        assertEq(contributionBeforeFee, 250e6); // new plan
        assertEq(contributionAfterFee, 182_500_000);
        assertEq(fee, 13_715_279); // previous one + new one
        assertEq(discount, 41_145_832);
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

        uint256 newContribution = 50e6;

        uint256 parentBalanceBefore = usdc.balanceOf(parent);

        assertEq(referralGateway.totalDonationsFromCoupons(), 0);

        vm.prank(couponRedeemer);
        (uint256 feeToOp, uint256 newDiscount) = referralGateway.lateContribution(
            newContribution,
            child,
            100e6, // 100 USDC coupon
            initialContributionTimestamp
        );

        uint256 parentBalanceAfter = usdc.balanceOf(parent);

        uint256 expectedTransfer = ((newContribution * (360 - 90)) / 360) -
            (newContribution * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100 -
            (newContribution * REFERRAL_DISCOUNT_RATIO) /
            100;

        assertEq(expectedTransfer, 31_875_000);
        // The fee to operator should be fee-disount-referralReserve-repoolFee
        assertEq(feeToOp, 7_500_000);

        (contributionBeforeFee, contributionAfterFee, fee, discount, isDonated) = referralGateway
            .getPrepaidMember(child);

        // assertEq(contributionBeforeFee, 50e6); // new plan
        // assertEq(contributionAfterFee, 182_500_000);
        // assertEq(fee, 13_715_279); // previous one + new one
        // assertEq(discount, 41_145_832);
        // assert(!isDonated);

        // assert(parentBalanceAfter > parentBalanceBefore);

        // assertEq(referralGateway.totalDonationsFromCoupons(), 50e6 - newContribution);
    }
}
