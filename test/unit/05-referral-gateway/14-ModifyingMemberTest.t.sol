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
    address parentLess = makeAddr("parentLess");
    address parent = makeAddr("parent");
    address couponPool = makeAddr("couponPool");
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "The LifeDAO";
    uint256 public constant USDC_INITIAL_AMOUNT = 1000e6; // 1000 USDC
    uint256 public constant MAX_CONTRIBUTION = 250e6; // 250 USDC
    uint256 public constant MIN_CONTRIBUTION = 25e6; // 25 USDC
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee
    uint256 public constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution deducted from fee

    event OnPrepaidMemberModified(
        address indexed member,
        uint256 indexed newPlan,
        uint256 indexed proratedAmount,
        uint256 extraFee,
        uint256 extraDiscount
    );

    event OnCouponRedeemed(
        address indexed member,
        string indexed tDAOName,
        uint256 indexed couponAmount
    );
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        // Deployer
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (, referralGatewayAddress, , , , , , , usdcAddress, , helperConfig) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        kycProvider = config.kycProvider;

        // Assign implementations
        referralGateway = ReferralGateway(address(referralGatewayAddress));
        usdc = IUSDC(usdcAddress);

        // Give USDC
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);
        deal(address(usdc), parentLess, USDC_INITIAL_AMOUNT);
        deal(address(usdc), parent, USDC_INITIAL_AMOUNT);
        deal(address(usdc), couponPool, 1000e6);

        // USDC approvals
        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);
        vm.prank(parentLess);
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

        // The parent and parentLess pays contributions
        vm.startPrank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            MAX_CONTRIBUTION,
            address(0),
            parent,
            MAX_CONTRIBUTION,
            false
        );
        referralGateway.payContributionOnBehalfOf(
            MIN_CONTRIBUTION,
            address(0),
            parentLess,
            MIN_CONTRIBUTION,
            true
        );
        vm.stopPrank();

        // KYC the parent so he can refer the child and receive referral rewards
        vm.prank(kycProvider);
        referralGateway.approveKYC(parent);

        // The child pays the minimum contribution without a coupon, using the parent as a referrer, and donates the contribution
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            MIN_CONTRIBUTION,
            parent,
            child,
            MIN_CONTRIBUTION,
            true
        );

        initialContributionTimestamp = block.timestamp;

        // KYC the child so the parent receive referral rewards
        vm.prank(kycProvider);
        referralGateway.approveKYC(child);
    }

    modifier turnOffAllDiscounts() {
        vm.startPrank(takadao);
        referralGateway.switchPrejoinDiscount();
        referralGateway.switchReferralDiscount();
        vm.stopPrank();
        _;
    }

    function testChildNowWantsThe25DollarPlanAfterThreeMonthsNoCoupons()
        public
        turnOffAllDiscounts
    {
        vm.warp(block.timestamp + 90 days);
        vm.roll(block.number + 1);

        // Remaining time 365 days - 90 days = 275 days
        // proratedAmount = 25 USDC * 275 / 365 = 18_835_616 USDC

        (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 fee,
            ,
            bool isDonated
        ) = referralGateway.getPrepaidMember(child);

        assertEq(contributionBeforeFee, MIN_CONTRIBUTION);
        assertEq(contributionAfterFee, 1825e4);
        assertEq(fee, 5e6);
        assert(isDonated);

        // The child now wants to upgrade to the 25 USDC plan, so the new contribution is prorated
        uint256 newContribution = MIN_CONTRIBUTION;

        uint256 parentBalanceBefore = usdc.balanceOf(parent); // 776_000_000
        uint256 childBalanceBefore = usdc.balanceOf(child); // 978_750_000
        uint256 couponPoolBalanceBefore = usdc.balanceOf(couponPool); // 1_000_000_000

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrepaidMemberModified(child, newContribution, 18_835_616, 941_783, 2_825_341);
        (uint256 feeToOp, uint256 newDiscount) = referralGateway.payContributionAfterWaive(
            newContribution,
            child,
            0, // no coupon
            initialContributionTimestamp,
            block.timestamp
        );

        assertEq(feeToOp, 3_767_124);
        assertEq(newDiscount, 0);

        (contributionBeforeFee, contributionAfterFee, fee, , isDonated) = referralGateway
            .getPrepaidMember(child);

        assertEq(contributionBeforeFee, MIN_CONTRIBUTION); // new plan
        assertEq(contributionAfterFee, 18_250_000);
        assertEq(fee, 8_767_124); // previous one + new one
        assert(!isDonated);

        uint256 parentBalanceDelta = usdc.balanceOf(parent) - parentBalanceBefore;
        uint256 childBalanceDelta = childBalanceBefore - usdc.balanceOf(child);
        uint256 reward = (childBalanceDelta * 4) / 100;

        assert(usdc.balanceOf(parent) > parentBalanceBefore);
        assert(usdc.balanceOf(child) < childBalanceBefore);
        assertEq(usdc.balanceOf(couponPool), couponPoolBalanceBefore);
        // The reward should be 4% of the prorated amount:
        assertEq(parentBalanceDelta, reward);
        assertEq(childBalanceDelta, 18_835_616);
    }

    function testChildNowWantsThe50DollarPlanAfterThreeMonthsNoCoupons() public {
        vm.warp(block.timestamp + 90 days);
        vm.roll(block.number + 1);

        (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 fee,
            ,
            bool isDonated
        ) = referralGateway.getPrepaidMember(child);

        assertEq(contributionBeforeFee, MIN_CONTRIBUTION);
        assertEq(contributionAfterFee, 1825e4);
        assertEq(fee, 5e6);
        assert(isDonated);

        // The child now wants to upgrade to the 50 USDC plan, so the new contribution is prorated
        uint256 newContribution = 50e6; // 50 USDC

        uint256 parentBalanceBefore = usdc.balanceOf(parent);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrepaidMemberModified(child, newContribution, 37_671_232, 1_883_563, 5_650_684);
        (uint256 feeToOp, uint256 newDiscount) = referralGateway.payContributionAfterWaive(
            newContribution,
            child,
            0, // no coupon
            initialContributionTimestamp,
            block.timestamp
        );

        uint256 parentBalanceAfter = usdc.balanceOf(parent);

        assertEq(feeToOp, 1_883_563);
        assertEq(newDiscount, 5_650_684);

        (contributionBeforeFee, contributionAfterFee, fee, , isDonated) = referralGateway
            .getPrepaidMember(child);

        assertEq(contributionBeforeFee, 50e6); // new plan
        assertEq(contributionAfterFee, 36_500_000);
        assertEq(fee, 6_883_563); // previous one + new one
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
            ,
            bool isDonated
        ) = referralGateway.getPrepaidMember(child);

        assertEq(contributionBeforeFee, MIN_CONTRIBUTION);
        assertEq(contributionAfterFee, 1825e4);
        assertEq(fee, 5e6);
        assert(isDonated);

        // The child now wants to upgrade to the 250 USDC plan, so the new contribution is prorated
        uint256 newContribution = 250e6;

        uint256 parentBalanceBefore = usdc.balanceOf(parent);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrepaidMemberModified(child, newContribution, 188_356_164, 9_417_809, 28_253_424);
        (uint256 feeToOp, uint256 newDiscount) = referralGateway.payContributionAfterWaive(
            newContribution,
            child,
            0, // no coupon
            initialContributionTimestamp,
            block.timestamp
        );

        uint256 parentBalanceAfter = usdc.balanceOf(parent);

        assertEq(feeToOp, 9_417_809);
        assertEq(newDiscount, 28_253_424);

        (contributionBeforeFee, contributionAfterFee, fee, , isDonated) = referralGateway
            .getPrepaidMember(child);

        assertEq(contributionBeforeFee, 250e6); // new plan
        assertEq(contributionAfterFee, 182_500_000);
        assertEq(fee, 14_417_809); // previous one + new one
        assert(!isDonated);

        assert(parentBalanceAfter > parentBalanceBefore);
    }

    function testChildNowWantsThe50DollarPlanAfterThreeMonthsExtraCoupon() public {
        assertEq(referralGateway.totalDonationsFromCoupons(), 0);

        vm.warp(block.timestamp + 90 days);
        vm.roll(block.number + 1);

        (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 fee,
            ,
            bool isDonated
        ) = referralGateway.getPrepaidMember(child);

        assertEq(contributionBeforeFee, MIN_CONTRIBUTION);
        assertEq(contributionAfterFee, 1825e4);
        assertEq(fee, 5e6);
        assert(isDonated);

        uint256 newContribution = 50e6;
        uint256 couponAmount = 50e6; // 50 USDC coupon

        uint256 parentBalanceBefore = usdc.balanceOf(parent);

        assertEq(referralGateway.totalDonationsFromCoupons(), 0);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrepaidMemberModified(child, newContribution, 37_671_232, 7_534_247, 0);
        (uint256 feeToOp, uint256 newDiscount) = referralGateway.payContributionAfterWaive(
            newContribution,
            child,
            couponAmount,
            initialContributionTimestamp,
            block.timestamp
        );

        uint256 parentBalanceAfter = usdc.balanceOf(parent);

        // The fee to operator should be fee-disount-referralReserve-repoolFee
        assertEq(feeToOp, 7_534_247);
        assertEq(newDiscount, 0);

        (contributionBeforeFee, contributionAfterFee, fee, , isDonated) = referralGateway
            .getPrepaidMember(child);

        assertEq(contributionBeforeFee, 50e6); // new plan
        assertEq(contributionAfterFee, 36_500_000);
        assertEq(fee, 12_534_247); // previous one + new one
        assert(!isDonated);

        assert(parentBalanceAfter > parentBalanceBefore);

        assert(referralGateway.totalDonationsFromCoupons() > 0);
        assert(referralGateway.totalDonationsFromCoupons() < couponAmount);
    }

    function test25PlanWithParent100daysRemainsCouponEqualsContribution()
        public
        turnOffAllDiscounts
    {
        vm.warp(block.timestamp + 265 days); // 100 days remaining of 365
        vm.roll(block.number + 1);

        (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 fee,
            ,
            bool isDonated
        ) = referralGateway.getPrepaidMember(child);

        assertEq(contributionBeforeFee, MIN_CONTRIBUTION);
        assertEq(contributionAfterFee, 1825e4);
        assertEq(fee, 5e6);
        assert(isDonated);

        uint256 newPlan = MIN_CONTRIBUTION;

        assertEq(referralGateway.totalDonationsFromCoupons(), 0);

        // proratedAmount = 25 USDC * 100 / 365 = 6_849_315 USDC
        vm.prank(couponRedeemer);
        // Transfer from coupon pool to referral gateway, emitted by USDC token
        vm.expectEmit(true, true, false, true, usdcAddress);
        emit Transfer(couponPool, address(referralGateway), newPlan);
        // Transfer the reward, 6_849_315 * 4% = 273_972, emitted by USDC token.
        vm.expectEmit(true, true, false, true, usdcAddress);
        emit Transfer(address(referralGateway), parent, 273_972);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrepaidMemberModified(child, newPlan, 6_849_315, 1_369_864, 0);
        (uint256 feeToOp, uint256 newDiscount) = referralGateway.payContributionAfterWaive(
            newPlan,
            child,
            newPlan,
            initialContributionTimestamp,
            block.timestamp
        );

        // coupon - proratedAmount = 25e6 - 6_849_315 = 18_150_685 donated
        assertEq(referralGateway.totalDonationsFromCoupons(), 18_150_685);

        // The fee to operator should be fee-referralReserve-repoolFee
        assertEq(feeToOp, 1_369_864);
        assertEq(newDiscount, 0);

        (contributionBeforeFee, contributionAfterFee, fee, , isDonated) = referralGateway
            .getPrepaidMember(child);

        assertEq(contributionBeforeFee, MIN_CONTRIBUTION); // new plan
        assertEq(contributionAfterFee, 18_250_000);
        assertEq(fee, 6_369_864); // previous one + new one
        assert(!isDonated);
    }

    function test100PlanWithoutParent200daysRemainsCouponEqualsContribution()
        public
        turnOffAllDiscounts
    {
        vm.warp(block.timestamp + 165 days); // 200 days remaining of 365
        vm.roll(block.number + 1);

        (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 fee,
            ,
            bool isDonated
        ) = referralGateway.getPrepaidMember(parentLess);

        assertEq(contributionBeforeFee, MIN_CONTRIBUTION);
        assertEq(contributionAfterFee, 1825e4);
        assertEq(fee, 5_000_000);
        assert(isDonated);

        uint256 newPlan = 100e6;

        assertEq(referralGateway.totalDonationsFromCoupons(), 0);

        // proratedAmount = 100 USDC * 200 / 365 = 54_794_520 USDC
        vm.prank(couponRedeemer);
        // Transfer from coupon pool to referral gateway, emitted by USDC token
        vm.expectEmit(true, true, false, true, usdcAddress);
        emit Transfer(couponPool, address(referralGateway), newPlan);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrepaidMemberModified(parentLess, newPlan, 54_794_520, 10_958_904, 0);
        (uint256 feeToOp, uint256 newDiscount) = referralGateway.payContributionAfterWaive(
            newPlan,
            parentLess,
            newPlan,
            initialContributionTimestamp,
            block.timestamp
        );

        // coupon - proratedAmount = 100e6 - 54_794_520 = 45_205_480 donated
        assertEq(referralGateway.totalDonationsFromCoupons(), 45_205_480);

        // The fee to operator should be fee-referralReserve-repoolFee
        assertEq(feeToOp, 10_958_904);
        assertEq(newDiscount, 0);

        (contributionBeforeFee, contributionAfterFee, fee, , isDonated) = referralGateway
            .getPrepaidMember(parentLess);

        assertEq(contributionBeforeFee, newPlan); // new plan
        assertEq(contributionAfterFee, 73_000_000);
        assertEq(fee, 15_958_904); // previous one + new one
        assert(!isDonated);
    }

    function test250PlanWithoutParent350daysRemainsCouponEqualsContribution()
        public
        turnOffAllDiscounts
    {
        vm.warp(block.timestamp + 15 days); // 350 days remaining of 365
        vm.roll(block.number + 1);

        (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 fee,
            ,
            bool isDonated
        ) = referralGateway.getPrepaidMember(parentLess);

        assertEq(contributionBeforeFee, MIN_CONTRIBUTION);
        assertEq(contributionAfterFee, 1825e4);
        assertEq(fee, 5_000_000);
        assert(isDonated);

        uint256 newPlan = 250e6;

        assertEq(referralGateway.totalDonationsFromCoupons(), 0);

        // proratedAmount = 250 USDC * 350 / 365 = 239_726_027 USDC
        vm.prank(couponRedeemer);
        // Transfer from coupon pool to referral gateway, emitted by USDC token
        vm.expectEmit(true, true, false, true, usdcAddress);
        emit Transfer(couponPool, address(referralGateway), newPlan);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrepaidMemberModified(parentLess, newPlan, 239_726_027, 47_945_206, 0);
        (uint256 feeToOp, uint256 newDiscount) = referralGateway.payContributionAfterWaive(
            newPlan,
            parentLess,
            newPlan,
            initialContributionTimestamp,
            block.timestamp
        );

        // coupon - proratedAmount = 250e6 - 239_726_027 = 10_273_973 donated
        assertEq(referralGateway.totalDonationsFromCoupons(), 10_273_973);

        // The fee to operator should be fee-referralReserve-repoolFee
        assertEq(feeToOp, 47_945_206);
        assertEq(newDiscount, 0);

        (contributionBeforeFee, contributionAfterFee, fee, , isDonated) = referralGateway
            .getPrepaidMember(parentLess);

        assertEq(contributionBeforeFee, newPlan); // new plan
        assertEq(contributionAfterFee, 182_500_000);
        assertEq(fee, 52_945_206); // previous one + new one
        assert(!isDonated);
    }

    function testCanNotWaiveTwice() public {
        vm.warp(block.timestamp + 15 days);
        vm.roll(block.number + 1);

        uint256 newPlan = 250e6;

        vm.startPrank(couponRedeemer);
        referralGateway.payContributionAfterWaive(
            newPlan,
            parentLess,
            newPlan,
            initialContributionTimestamp,
            block.timestamp
        );
        // Cannot waive twice right away
        vm.expectRevert(ReferralGateway.ReferralGateway__NotAllowedToModify.selector);
        referralGateway.payContributionAfterWaive(
            newPlan,
            parentLess,
            newPlan,
            initialContributionTimestamp,
            block.timestamp
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 15 days);
        vm.roll(block.number + 1);

        // cannot waive twice after time passed
        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__NotAllowedToModify.selector);
        referralGateway.payContributionAfterWaive(
            newPlan,
            parentLess,
            newPlan,
            initialContributionTimestamp,
            block.timestamp
        );
    }
}
