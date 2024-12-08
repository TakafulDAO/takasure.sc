// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract CouponCodeTest is Test {
    TestDeployTakasure deployer;
    ReferralGateway referralGateway;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address proxy;
    address operator;
    address child = makeAddr("child");
    address couponPool = makeAddr("couponPool");
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "TheLifeDao";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee

    event OnCouponRedeemed(
        address indexed member,
        string indexed tDAOName,
        uint256 indexed couponAmount
    );

    function setUp() public {
        // Deployer
        deployer = new TestDeployTakasure();
        // Deploy contracts
        (, bmConsumerMock, , proxy, usdcAddress, , helperConfig) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        operator = config.takadaoOperator;

        // Assign implementations
        referralGateway = ReferralGateway(address(proxy));
        usdc = IUSDC(usdcAddress);

        // Give and approve USDC
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);
        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);

        ReferralGateway newImplementation = new ReferralGateway();

        vm.prank(operator);
        referralGateway.upgradeToAndCall(
            address(newImplementation),
            abi.encodeCall(ReferralGateway.initializeNewVersion, (couponPool, couponRedeemer, 2))
        );

        deal(address(usdc), couponPool, 1000e6);

        vm.prank(couponPool);
        usdc.approve(address(referralGateway), 1000e6);

        vm.prank(config.daoMultisig);
        referralGateway.createDAO(tDaoName, true, true, 1743479999, 1e12, address(bmConsumerMock));
    }

    /*//////////////////////////////////////////////////////////////
                           COUPON PREPAYMENTS
    //////////////////////////////////////////////////////////////*/

    //======== coupon higher than contribution ========//
    function testCouponPrepaymentCase1() public {
        uint256 couponAmount = CONTRIBUTION_AMOUNT * 2;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(operator);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnCouponRedeemed(child, tDaoName, couponAmount);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            tDaoName,
            address(0),
            child,
            couponAmount
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(operator);

        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        assert(feeToOp > 0);

        (uint256 contributionBeforeFee, , , uint256 discount) = referralGateway.getPrepaidMember(
            child,
            tDaoName
        );

        assertEq(contributionBeforeFee, couponAmount);
        assertEq(discount, 0); // No discount as the coupon is consumed completely and covers the whole membership
    }

    //======== coupon equals than contribution ========//
    function testCouponPrepaymentCase2() public {
        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(operator);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnCouponRedeemed(child, tDaoName, couponAmount);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            tDaoName,
            address(0),
            child,
            couponAmount
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(operator);

        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        assert(feeToOp > 0);

        (uint256 contributionBeforeFee, , , uint256 discount) = referralGateway.getPrepaidMember(
            child,
            tDaoName
        );

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT);
        assertEq(discount, 0); // No discount as the coupon is consumed completely and covers the whole membership
    }

    //======== coupon less than contribution ========//
    function testCouponPrepaymentCase3() public {
        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(operator);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnCouponRedeemed(child, tDaoName, couponAmount);
        (uint256 feeToOp, ) = referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT * 2,
            tDaoName,
            address(0),
            child,
            couponAmount
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(operator);

        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        assert(feeToOp > 0);

        (uint256 contributionBeforeFee, , , uint256 discount) = referralGateway.getPrepaidMember(
            child,
            tDaoName
        );

        uint256 expectedDiscount = (((CONTRIBUTION_AMOUNT * 2) - couponAmount) *
            CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100;

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT * 2);
        assertEq(discount, expectedDiscount); // Applied to what is left after the coupon
    }
}
