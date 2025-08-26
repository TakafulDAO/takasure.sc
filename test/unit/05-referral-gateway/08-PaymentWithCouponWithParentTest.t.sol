// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ReferralGatewayWithCouponWithParentPaymentTest is Test {
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
    string tDaoName = "The LifeDao";
    uint256 public constant USDC_INITIAL_AMOUNT = 1000e6; // 1000 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 250e6; // 250 USDC
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee
    uint256 public constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution deducted from fee

    event OnNewCouponPoolAddress(address indexed oldCouponPool, address indexed newCouponPool);
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

        // Give and approve USDC
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);
        deal(address(usdc), parent, USDC_INITIAL_AMOUNT);

        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);

        vm.prank(parent);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);

        deal(address(usdc), couponPool, 1000e6);

        vm.prank(couponPool);
        usdc.approve(address(referralGateway), 1000e6);

        bytes memory strBytes = bytes(tDaoName);
        bytes32 slotValue;

        assembly {
            slotValue := mload(add(strBytes, 32))
        }

        uint256 lenFlagged = strBytes.length * 2;

        slotValue = (slotValue & ~bytes32(uint256(0xFF))) | bytes32(uint256(lenFlagged));

        vm.store(address(referralGateway), bytes32(uint256(9)), slotValue);

        vm.prank(config.daoMultisig);
        referralGateway.createDAO(true, true, 1743479999, 1e12);
    }

    function testSetNewCouponPoolAddress() public {
        vm.prank(takadao);
        vm.expectEmit(true, true, false, false, address(referralGateway));
        emit OnNewCouponPoolAddress(address(0), couponPool);
        referralGateway.setCouponPoolAddress(couponPool);
    }

    modifier setCouponPoolAndCouponRedeemer() {
        vm.startPrank(takadao);
        referralGateway.setCouponPoolAddress(couponPool);
        referralGateway.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        vm.stopPrank();
        _;
    }

    modifier parentJoinsAndKYC() {
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            parent,
            0,
            false
        );

        vm.prank(kycProvider);
        referralGateway.approveKYC(parent);

        _;
    }

    //======== preJoinEnabled = true, referralDiscount = true, rewardsEnabled = true, with parent, coupon equals contribution ========//
    function testPrepaymentCase33() public setCouponPoolAndCouponRedeemer parentJoinsAndKYC {
        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(takadao);
        uint256 initialChildBalance = usdc.balanceOf(child);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnCouponRedeemed(child, tDaoName, couponAmount);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            parent,
            child,
            couponAmount,
            false
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(takadao);
        uint256 finalChildBalance = usdc.balanceOf(child);

        // The coupon pool balance should decrease by the coupon amount
        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        // The operator balance should increase by the fee to operator
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        // The child's balance should remain the same because the coupon covers the entire contribution
        assertEq(finalChildBalance, initialChildBalance);
        // The fee to operator should be fee-disount-referralReserve-repoolFee
        // (250 * 27%) - 0 - (250 * 5%) - (250 * 2%) = 67.5 - 0 - 12.5 - 5 = 50
        assertEq(feeToOp, 50e6);

        (uint256 contributionBeforeFee, , , uint256 discount) = referralGateway.getPrepaidMember(
            child
        );

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT);
        assertEq(discount, 0); // No discount as the coupon is consumed completely and covers the whole membership
    }

    //======== preJoinEnabled = true, referralDiscount = true, rewardsEnabled = true, with parent, coupon less than contribution ========//
    function testPrepaymentCase34() public setCouponPoolAndCouponRedeemer parentJoinsAndKYC {
        uint256 couponAmount = 100e6; // 100 USDC

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(takadao);
        uint256 initialChildBalance = usdc.balanceOf(child);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnCouponRedeemed(child, tDaoName, couponAmount);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            parent,
            child,
            couponAmount,
            false
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(takadao);
        uint256 finalChildBalance = usdc.balanceOf(child);
        uint256 prejoinDiscount = ((CONTRIBUTION_AMOUNT - couponAmount) *
            CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100;
        uint256 referralDiscount = ((CONTRIBUTION_AMOUNT - couponAmount) *
            REFERRAL_DISCOUNT_RATIO) / 100;
        uint256 expectedDiscount = prejoinDiscount + referralDiscount;
        // (contribution - coupon) - (((contribution - coupon) * prejoinDiscount) + ((contribution - coupon) * referralDiscount))
        // (250 - 100) - (((250 - 100) * 10%) + ((250 - 100) * 5%)) = 150 - (15 + 7.5) = 150 - 22.5 = 127.5
        uint256 expectedTransfer = (CONTRIBUTION_AMOUNT - couponAmount) - expectedDiscount;

        // The coupon pool balance should decrease by the coupon amount
        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        // The operator balance should increase by the fee to operator
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        // The child's balance should decrease by the remaining contribution amount
        assertEq(finalChildBalance, initialChildBalance - expectedTransfer);
        assertEq(expectedTransfer, 1275e5);
        // The fee to operator should be fee-disount-referralReserve-repoolFee
        assertEq(feeToOp, 275e5);
        assertEq(expectedDiscount, 225e5);

        (uint256 contributionBeforeFee, , , uint256 discount) = referralGateway.getPrepaidMember(
            child
        );

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT);
        assertEq(discount, expectedDiscount); // Applied to what is left after the coupon
    }

    //======== preJoinEnabled = true, referralDiscount = true, rewardsEnabled = false, with parent, coupon equals contribution ========//
    function testPrepaymentCase35() public setCouponPoolAndCouponRedeemer parentJoinsAndKYC {
        vm.prank(takadao);
        referralGateway.switchRewardsDistribution();

        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__IncompatibleSettings.selector);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            parent,
            child,
            couponAmount,
            false
        );
    }

    //======== preJoinEnabled = true, referralDiscount = true, rewardsEnabled = false, with parent, coupon less than contribution ========//
    function testPrepaymentCase36() public setCouponPoolAndCouponRedeemer parentJoinsAndKYC {
        vm.prank(takadao);
        referralGateway.switchRewardsDistribution();

        uint256 couponAmount = 100e6; // 100 USDC

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__IncompatibleSettings.selector);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            parent,
            child,
            couponAmount,
            false
        );
    }

    //======== preJoinEnabled = true, referralDiscount = false, rewardsEnabled = true, with parent, coupon equals contribution ========//
    function testPrepaymentCase37() public setCouponPoolAndCouponRedeemer parentJoinsAndKYC {
        vm.prank(takadao);
        referralGateway.switchReferralDiscount();

        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(takadao);
        uint256 initialChildBalance = usdc.balanceOf(child);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnCouponRedeemed(child, tDaoName, couponAmount);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            parent,
            child,
            couponAmount,
            false
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(takadao);
        uint256 finalChildBalance = usdc.balanceOf(child);

        // The coupon pool balance should decrease by the coupon amount
        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        // The operator balance should increase by the fee to operator
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        // The child's balance should remain the same because the coupon covers the entire contribution
        assertEq(finalChildBalance, initialChildBalance);
        // The fee to operator should be fee-disount-referralReserve-repoolFee
        // (250 * 27%) - 0 - (250 * 5%) - (250 * 2%) = 67.5 - 0 - 12.5 - 5 = 50
        assertEq(feeToOp, 50_000_000);

        (uint256 contributionBeforeFee, , , uint256 discount) = referralGateway.getPrepaidMember(
            child
        );

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT);
        assertEq(discount, 0); // No discount as the coupon is consumed completely and covers the whole membership
    }

    //======== preJoinEnabled = true, referralDiscount = false, rewardsEnabled = true, with parent, coupon less than contribution ========//
    function testPrepaymentCase38() public setCouponPoolAndCouponRedeemer parentJoinsAndKYC {
        vm.prank(takadao);
        referralGateway.switchReferralDiscount();

        uint256 couponAmount = 100e6; // 100 USDC

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(takadao);
        uint256 initialChildBalance = usdc.balanceOf(child);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnCouponRedeemed(child, tDaoName, couponAmount);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            parent,
            child,
            couponAmount,
            false
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(takadao);
        uint256 finalChildBalance = usdc.balanceOf(child);
        uint256 prejoinDiscount = ((CONTRIBUTION_AMOUNT - couponAmount) *
            CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100; // (250 -100) * 10 / 100 = 15
        uint256 expectedDiscount = prejoinDiscount; // 15
        // (contribution - coupon) - (((contribution - coupon) * prejoinDiscount) + ())
        // (250 - 100) - 15 - 7.5 = 127.5
        uint256 expectedTransfer = (CONTRIBUTION_AMOUNT - couponAmount) - expectedDiscount;

        // The coupon pool balance should decrease by the coupon amount
        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        // The operator balance should increase by the fee to operator
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        // The child's balance should decrease by the remaining contribution amount
        assertEq(finalChildBalance, initialChildBalance - expectedTransfer);
        assertEq(expectedTransfer, 135_000_000);
        // The fee to operator should be fee-disount-referralReserve-repoolFee
        assertEq(feeToOp, 35_000_000);
        assertEq(expectedDiscount, 15_000_000);

        (uint256 contributionBeforeFee, , , uint256 discount) = referralGateway.getPrepaidMember(
            child
        );

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT);
        assertEq(discount, expectedDiscount); // Applied to what is left after the coupon
    }

    //======== preJoinEnabled = true, referralDiscount = false, rewardsEnabled = false, with parent, coupon equals contribution ========//
    function testPrepaymentCase39() public setCouponPoolAndCouponRedeemer parentJoinsAndKYC {
        vm.startPrank(takadao);
        referralGateway.switchReferralDiscount();
        referralGateway.switchRewardsDistribution();
        vm.stopPrank();

        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__IncompatibleSettings.selector);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            parent,
            child,
            couponAmount,
            false
        );
    }

    //======== preJoinEnabled = true, referralDiscount = false, rewardsEnabled = false, with parent, coupon less than contribution ========//
    function testPrepaymentCase40() public setCouponPoolAndCouponRedeemer parentJoinsAndKYC {
        vm.startPrank(takadao);
        referralGateway.switchReferralDiscount();
        referralGateway.switchRewardsDistribution();
        vm.stopPrank();

        uint256 couponAmount = 100e6; // 100 USDC

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__IncompatibleSettings.selector);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            parent,
            child,
            couponAmount,
            false
        );
    }

    //======== preJoinEnabled = false, referralDiscount = true, rewardsEnabled = true, with parent, coupon equals contribution ========//
    function testPrepaymentCase41() public setCouponPoolAndCouponRedeemer parentJoinsAndKYC {
        vm.prank(takadao);
        referralGateway.switchPrejoinDiscount();

        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(takadao);
        uint256 initialChildBalance = usdc.balanceOf(child);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnCouponRedeemed(child, tDaoName, couponAmount);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            parent,
            child,
            couponAmount,
            false
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(takadao);
        uint256 finalChildBalance = usdc.balanceOf(child);

        // The coupon pool balance should decrease by the coupon amount
        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        // The operator balance should increase by the fee to operator
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        // The child's balance should remain the same because the coupon covers the entire contribution
        assertEq(finalChildBalance, initialChildBalance);
        // The fee to operator should be fee-disount-referralReserve-repoolFee
        // (250 * 27%) - 0 - (250 * 5%) - (250 * 2%) = 67.5 - 0 - 12.5 - 5 = 50
        assertEq(feeToOp, 50e6);

        (uint256 contributionBeforeFee, , , uint256 discount) = referralGateway.getPrepaidMember(
            child
        );

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT);
        assertEq(discount, 0); // No discount as the coupon is consumed completely and covers the whole membership
    }

    //======== preJoinEnabled = false, referralDiscount = true, rewardsEnabled = true, with parent, coupon less than contribution ========//
    function testPrepaymentCase42() public setCouponPoolAndCouponRedeemer parentJoinsAndKYC {
        vm.prank(takadao);
        referralGateway.switchPrejoinDiscount();

        uint256 couponAmount = 100e6; // 100 USDC

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(takadao);
        uint256 initialChildBalance = usdc.balanceOf(child);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnCouponRedeemed(child, tDaoName, couponAmount);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            parent,
            child,
            couponAmount,
            false
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(takadao);
        uint256 finalChildBalance = usdc.balanceOf(child);
        uint256 referralDiscount = ((CONTRIBUTION_AMOUNT - couponAmount) *
            REFERRAL_DISCOUNT_RATIO) / 100;
        uint256 expectedDiscount = referralDiscount;
        // (contribution - coupon) - (((contribution - coupon) * prejoinDiscount) + ((contribution - coupon) * referralDiscount))
        // (250 - 100) - (250 - 100) * 5%) = 150 - 7.5 = 142.5
        uint256 expectedTransfer = (CONTRIBUTION_AMOUNT - couponAmount) - expectedDiscount;

        // The coupon pool balance should decrease by the coupon amount
        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        // The operator balance should increase by the fee to operator
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        // The child's balance should decrease by the remaining contribution amount
        assertEq(finalChildBalance, initialChildBalance - expectedTransfer);
        assertEq(expectedTransfer, 1425e5);
        // The fee to operator should be fee-disount-referralReserve-repoolFee
        assertEq(feeToOp, 425e5);
        assertEq(expectedDiscount, 75e5);

        (uint256 contributionBeforeFee, , , uint256 discount) = referralGateway.getPrepaidMember(
            child
        );

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT);
        assertEq(discount, expectedDiscount); // Applied to what is left after the coupon
    }

    //======== preJoinEnabled = false, referralDiscount = true, rewardsEnabled = false, with parent, coupon equals contribution ========//
    function testPrepaymentCase43() public setCouponPoolAndCouponRedeemer parentJoinsAndKYC {
        vm.startPrank(takadao);
        referralGateway.switchPrejoinDiscount();
        referralGateway.switchRewardsDistribution();
        vm.stopPrank();

        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__IncompatibleSettings.selector);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            parent,
            child,
            couponAmount,
            false
        );
    }

    //======== preJoinEnabled = false, referralDiscount = true, rewardsEnabled = false, with parent, coupon less than contribution ========//
    function testPrepaymentCase44() public setCouponPoolAndCouponRedeemer parentJoinsAndKYC {
        vm.startPrank(takadao);
        referralGateway.switchPrejoinDiscount();
        referralGateway.switchRewardsDistribution();
        vm.stopPrank();

        uint256 couponAmount = 100e6; // 100 USDC

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__IncompatibleSettings.selector);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            parent,
            child,
            couponAmount,
            false
        );
    }

    //======== preJoinEnabled = false, referralDiscount = false, rewardsEnabled = true, with parent, coupon equals contribution ========//
    function testPrepaymentCase45() public setCouponPoolAndCouponRedeemer parentJoinsAndKYC {
        vm.startPrank(takadao);
        referralGateway.switchPrejoinDiscount();
        referralGateway.switchReferralDiscount();
        vm.stopPrank();

        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(takadao);
        uint256 initialChildBalance = usdc.balanceOf(child);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnCouponRedeemed(child, tDaoName, couponAmount);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            parent,
            child,
            couponAmount,
            false
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(takadao);
        uint256 finalChildBalance = usdc.balanceOf(child);

        // The coupon pool balance should decrease by the coupon amount
        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        // The operator balance should increase by the fee to operator
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        // The child's balance should remain the same because the coupon covers the entire contribution
        assertEq(finalChildBalance, initialChildBalance);
        // The fee to operator should be fee-disount-referralReserve-repoolFee
        assertEq(feeToOp, 50_000_000);

        (uint256 contributionBeforeFee, , , uint256 discount) = referralGateway.getPrepaidMember(
            child
        );

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT);
        assertEq(discount, 0); // No discount as the coupon is consumed completely and covers the whole membership
    }

    //======== preJoinEnabled = false, referralDiscount = false, rewardsEnabled = true, with parent, coupon less than contribution ========//
    function testPrepaymentCase46() public setCouponPoolAndCouponRedeemer parentJoinsAndKYC {
        vm.startPrank(takadao);
        referralGateway.switchPrejoinDiscount();
        referralGateway.switchReferralDiscount();
        vm.stopPrank();

        uint256 couponAmount = 100e6; // 100 USDC

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(takadao);
        uint256 initialChildBalance = usdc.balanceOf(child);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnCouponRedeemed(child, tDaoName, couponAmount);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            parent,
            child,
            couponAmount,
            false
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(takadao);
        uint256 finalChildBalance = usdc.balanceOf(child);
        // (contribution - coupon) - (((contribution - coupon) * prejoinDiscount) + ((contribution - coupon) * referralDiscount))
        // (250 - 100) - (250 - 100) * 5%) = 150 - 7.5 = 142.5
        uint256 expectedTransfer = (CONTRIBUTION_AMOUNT - couponAmount);

        // The coupon pool balance should decrease by the coupon amount
        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        // The operator balance should increase by the fee to operator
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        // The child's balance should decrease by the remaining contribution amount
        assertEq(finalChildBalance, initialChildBalance - expectedTransfer);
        assertEq(expectedTransfer, 150_000_000);
        // The fee to operator should be fee-disount-referralReserve-repoolFee
        assertEq(feeToOp, 50_000_000);

        (uint256 contributionBeforeFee, , , uint256 discount) = referralGateway.getPrepaidMember(
            child
        );

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT);
        assertEq(discount, 0);
    }

    //======== preJoinEnabled = false, referralDiscount = false, rewardsEnabled = false, with parent, coupon equals contribution ========//
    function testPrepaymentCase47() public setCouponPoolAndCouponRedeemer parentJoinsAndKYC {
        vm.startPrank(takadao);
        referralGateway.switchPrejoinDiscount();
        referralGateway.switchReferralDiscount();
        referralGateway.switchRewardsDistribution();
        vm.stopPrank();

        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__IncompatibleSettings.selector);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            parent,
            child,
            couponAmount,
            false
        );
    }

    //======== preJoinEnabled = false, referralDiscount = false, rewardsEnabled = false, with parent, coupon less than contribution ========//
    function testPrepaymentCase48() public setCouponPoolAndCouponRedeemer parentJoinsAndKYC {
        vm.startPrank(takadao);
        referralGateway.switchPrejoinDiscount();
        referralGateway.switchReferralDiscount();
        referralGateway.switchRewardsDistribution();
        vm.stopPrank();

        uint256 couponAmount = 100e6; // 100 USDC

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__IncompatibleSettings.selector);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            parent,
            child,
            couponAmount,
            false
        );
    }
}
