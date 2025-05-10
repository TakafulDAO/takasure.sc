// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {PrejoinModule} from "contracts/modules/PrejoinModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract CouponCodeTest is Test {
    TestDeployProtocol deployer;
    PrejoinModule prejoinModule;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address prejoinModuleAddress;
    address operator;
    address child = makeAddr("child");
    address couponPool = makeAddr("couponPool");
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "TheLifeDao";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee

    event OnNewCouponPoolAddress(address indexed oldCouponPool, address indexed newCouponPool);
    event OnCouponRedeemed(address indexed member, uint256 indexed couponAmount);

    function setUp() public {
        // Deployer
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (, bmConsumerMock, , prejoinModuleAddress, , , , , usdcAddress, , helperConfig) = deployer
            .run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        operator = config.takadaoOperator;

        // Assign implementations
        prejoinModule = PrejoinModule(address(prejoinModuleAddress));
        usdc = IUSDC(usdcAddress);

        // Give and approve USDC
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);
        vm.prank(child);
        usdc.approve(address(prejoinModule), USDC_INITIAL_AMOUNT);

        deal(address(usdc), couponPool, 1000e6);

        vm.prank(couponPool);
        usdc.approve(address(prejoinModule), 1000e6);

        vm.startPrank(config.daoMultisig);
        prejoinModule.createDAO(tDaoName, true, 1743479999, address(bmConsumerMock));
        prejoinModule.setDAOName(tDaoName);
        vm.stopPrank();

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(prejoinModuleAddress);
    }

    function testSetNewCouponPoolAddress() public {
        vm.prank(operator);
        vm.expectEmit(true, true, false, false, address(prejoinModule));
        emit OnNewCouponPoolAddress(address(0), couponPool);
        prejoinModule.setCouponPoolAddress(couponPool);
    }

    modifier setCouponPoolAndCouponRedeemer() {
        vm.startPrank(operator);
        prejoinModule.setCouponPoolAddress(couponPool);
        prejoinModule.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        vm.stopPrank();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           COUPON PREPAYMENTS
    //////////////////////////////////////////////////////////////*/

    //======== coupon higher than contribution ========//
    function testCouponPrepaymentCase1() public setCouponPoolAndCouponRedeemer {
        uint256 couponAmount = CONTRIBUTION_AMOUNT * 2;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(operator);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(prejoinModule));
        emit OnCouponRedeemed(child, couponAmount);
        (uint256 feeToOp, ) = prejoinModule.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            child,
            couponAmount
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(operator);

        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        assert(feeToOp > 0);

        (uint256 contributionBeforeFee, , , uint256 discount) = prejoinModule.getPrepaidMember(
            child
        );

        assertEq(contributionBeforeFee, couponAmount);
        assertEq(discount, 0); // No discount as the coupon is consumed completely and covers the whole membership
    }

    //======== coupon equals than contribution ========//
    function testCouponPrepaymentCase2() public setCouponPoolAndCouponRedeemer {
        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(operator);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(prejoinModule));
        emit OnCouponRedeemed(child, couponAmount);
        (uint256 feeToOp, ) = prejoinModule.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            child,
            couponAmount
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(operator);

        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        assert(feeToOp > 0);

        (uint256 contributionBeforeFee, , , uint256 discount) = prejoinModule.getPrepaidMember(
            child
        );

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT);
        assertEq(discount, 0); // No discount as the coupon is consumed completely and covers the whole membership
    }

    //======== coupon less than contribution ========//
    function testCouponPrepaymentCase3() public setCouponPoolAndCouponRedeemer {
        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(operator);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(prejoinModule));
        emit OnCouponRedeemed(child, couponAmount);
        (uint256 feeToOp, ) = prejoinModule.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT * 2,
            address(0),
            child,
            couponAmount
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(operator);

        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        assert(feeToOp > 0);

        (uint256 contributionBeforeFee, , , uint256 discount) = prejoinModule.getPrepaidMember(
            child
        );

        uint256 expectedDiscount = (((CONTRIBUTION_AMOUNT * 2) - couponAmount) *
            CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100;

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT * 2);
        assertEq(discount, expectedDiscount); // Applied to what is left after the coupon
    }

    //======== no coupon ========//
    function testShouldNotRevertIfThereIsNoCouponPool() public setCouponPoolAndCouponRedeemer {
        vm.prank(child);
        (uint256 feeToOp, uint256 discount) = prejoinModule.payContribution(
            CONTRIBUTION_AMOUNT,
            address(0)
        );

        assert(feeToOp > 0);
        assert(discount > 0);
    }
}
