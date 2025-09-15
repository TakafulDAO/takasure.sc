// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {DaoDataReader, IReferralGateway} from "test/helpers/lowLevelCall/DaoDataReader.sol";

contract ReferralGatewayNoCouponNoParentPaymentTest is Test {
    TestDeployProtocol deployer;
    ReferralGateway referralGateway;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address referralGatewayAddress;
    address takadao;
    address nonKycParent = makeAddr("nonKycParent");
    address child = makeAddr("child");
    address couponRedeemer = makeAddr("couponRedeemer");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint8 public constant SERVICE_FEE_RATIO = 27;
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee
    uint256 public constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution TO Referral Reserve
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
        (, referralGatewayAddress, , , , , , usdcAddress, , helperConfig) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;

        // Assign implementations
        referralGateway = ReferralGateway(referralGatewayAddress);
        usdc = IUSDC(usdcAddress);

        // Give and approve USDC
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);

        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);

        vm.startPrank(takadao);
        referralGateway.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        referralGateway.createDAO(true, true, 1743479999, 1e12);
        vm.stopPrank();
    }

    function testPrepaymentDonatedTrue() public {
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, address(0), child, 0, true);

        (uint256 contributionBeforeFee, , , , ) = referralGateway.getPrepaidMember(child);

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT);
    }

    //======== preJoinDiscountEnabled = true, referralDiscountEnabled = true, rewardsEnabled = true, no parent, no coupon ========//
    function testPrepaymentCase1() public {
        uint256 alreadyCollectedFees = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            8
        );

        assertEq(alreadyCollectedFees, 0);

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            (((CONTRIBUTION_AMOUNT * REFERRAL_RESERVE) / 100)) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = (CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100;

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(address(0), child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, address(0), child, 0, false);

        (, , , uint256 discount, ) = referralGateway.getPrepaidMember(child);

        uint256 totalCollectedFees = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            8
        );

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 2_500_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinDiscountEnabled = true, referralDiscountEnabled = true, rewardsEnabled = false, no parent, no coupon ========//
    function testPrepaymentCase2() public {
        vm.prank(takadao);
        referralGateway.switchRewardsDistribution();

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__IncompatibleSettings.selector);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, address(0), child, 0, false);
    }

    //======== preJoinDiscountEnabled = true, referralDiscountEnabled = false, rewardsEnabled = true, no parent, no coupon ========//
    function testPrepaymentCase3() public {
        vm.prank(takadao);
        referralGateway.switchReferralDiscount();

        uint256 alreadyCollectedFees = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            8
        );

        assertEq(alreadyCollectedFees, 0);

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REFERRAL_RESERVE) / 100);

        uint256 expectedDiscount = (CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100;

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(address(0), child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, address(0), child, 0, false);

        (, , , uint256 discount, ) = referralGateway.getPrepaidMember(child);

        uint256 totalCollectedFees = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            8
        );

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 2_500_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinDiscountEnabled = true, referralDiscountEnabled = false, rewardsEnabled = false, no parent, no coupon ========//
    function testPrepaymentCase4() public {
        vm.startPrank(takadao);
        referralGateway.switchReferralDiscount();
        referralGateway.switchRewardsDistribution();
        vm.stopPrank();

        uint256 alreadyCollectedFees = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            8
        );

        assertEq(alreadyCollectedFees, 0);

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = (CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100;

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(address(0), child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, address(0), child, 0, false);

        (, , , uint256 discount, ) = referralGateway.getPrepaidMember(child);

        uint256 totalCollectedFees = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            8
        );

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 3_750_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinDiscountEnabled = false, referralDiscountEnabled = true, rewardsEnabled = true, no parent, no coupon ========//
    function testPrepaymentCase5() public {
        vm.prank(takadao);
        referralGateway.switchPrejoinDiscount();

        uint256 alreadyCollectedFees = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            8
        );

        assertEq(alreadyCollectedFees, 0);

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            (((CONTRIBUTION_AMOUNT * REFERRAL_RESERVE) / 100)) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = 0;

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(address(0), child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, address(0), child, 0, false);

        (, , , uint256 discount, ) = referralGateway.getPrepaidMember(child);

        uint256 totalCollectedFees = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            8
        );

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 5_000_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinDiscountEnabled = false, referralDiscountEnabled = true, rewardsEnabled = false, no parent, no coupon ========//
    function testPrepaymentCase6() public {
        vm.startPrank(takadao);
        referralGateway.switchPrejoinDiscount(); // false
        referralGateway.switchRewardsDistribution(); // false
        vm.stopPrank();

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__IncompatibleSettings.selector);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, address(0), child, 0, false);
    }

    //======== preJoinDiscountEnabled = false, referralDiscountEnabled = false, rewardsEnabled = true, no parent, no coupon ========//
    function testPrepaymentCase7() public {
        vm.startPrank(takadao);
        referralGateway.switchPrejoinDiscount();
        referralGateway.switchReferralDiscount();
        vm.stopPrank();

        uint256 alreadyCollectedFees = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            8
        );

        assertEq(alreadyCollectedFees, 0);

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REFERRAL_RESERVE) / 100);

        uint256 expectedDiscount = 0;

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(address(0), child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, address(0), child, 0, false);

        (, , , uint256 discount, ) = referralGateway.getPrepaidMember(child);

        uint256 totalCollectedFees = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            8
        );

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 5_000_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinDiscountEnabled = false, referralDiscountEnabled = false, rewardsEnabled = false, no parent, no coupon ========//
    function testPrepaymentCase8() public {
        vm.startPrank(takadao);
        referralGateway.switchPrejoinDiscount();
        referralGateway.switchReferralDiscount();
        referralGateway.switchRewardsDistribution();
        vm.stopPrank();

        uint256 alreadyCollectedFees = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            8
        );

        assertEq(alreadyCollectedFees, 0);

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees - ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = 0;

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(address(0), child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, address(0), child, 0, false);

        (, , , uint256 discount, ) = referralGateway.getPrepaidMember(child);

        uint256 totalCollectedFees = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            8
        );

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 6_250_000);
        assertEq(discount, expectedDiscount);
    }
}
