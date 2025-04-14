// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {PrejoinModule} from "contracts/modules/PrejoinModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract CouponCodeAndCcipTest is Test {
    TestDeployProtocol deployer;
    PrejoinModule prejoinModule;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address prejoinModuleAddress;
    address operator;
    address couponUser = makeAddr("couponUser");
    address ccipUser = makeAddr("ccipUser");
    address couponPool = makeAddr("couponPool");
    address ccipReceiverContract = makeAddr("ccipReceiverContract");
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "TheLifeDao";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee

    event OnNewCouponPoolAddress(address indexed oldCouponPool, address indexed newCouponPool);
    event OnCouponRedeemed(address indexed member, uint256 indexed couponAmount);
    event OnNewCCIPReceiverContract(
        address indexed oldCCIPReceiverContract,
        address indexed newCCIPReceiverContract
    );

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

        // To the coupon user, he must pay part of the contribution
        deal(address(usdc), couponUser, USDC_INITIAL_AMOUNT);
        vm.prank(couponUser);
        usdc.approve(address(prejoinModule), USDC_INITIAL_AMOUNT);

        // To the coupon pool, it will be used to pay the coupon
        deal(address(usdc), couponPool, 1000e6);
        vm.prank(couponPool);
        usdc.approve(address(prejoinModule), 1000e6);

        // To the ccip receiver contract, it will be used to pay the contributions of the ccip user
        deal(address(usdc), ccipReceiverContract, 1000e6);
        vm.prank(ccipReceiverContract);
        usdc.approve(address(prejoinModule), 1000e6);

        vm.startPrank(config.daoMultisig);
        prejoinModule.setDAOName(tDaoName);
        prejoinModule.createDAO(true, true, 1743479999, 1e12, address(bmConsumerMock));
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

    function testSetNewCcipReceiverContract() public {
        vm.prank(operator);
        vm.expectEmit(true, true, false, false, address(prejoinModule));
        emit OnNewCCIPReceiverContract(address(0), ccipReceiverContract);
        prejoinModule.setCCIPReceiverContract(ccipReceiverContract);
    }

    modifier setCouponPoolAndCouponRedeemer() {
        vm.startPrank(operator);
        prejoinModule.setCouponPoolAddress(couponPool);
        prejoinModule.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        vm.stopPrank();
        _;
    }

    modifier setCcipReceiverContract() {
        vm.prank(operator);
        prejoinModule.setCCIPReceiverContract(ccipReceiverContract);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                       COUPON PREPAYMENTS NO CCIP
    //////////////////////////////////////////////////////////////*/

    //======== coupon higher than contribution ========//
    function testCouponPrepaymentNoCcipCase1() public setCouponPoolAndCouponRedeemer {
        uint256 couponAmount = CONTRIBUTION_AMOUNT * 2;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(operator);
        uint256 initialCouponUserBalance = usdc.balanceOf(couponUser);
        uint256 initialCCIPReceiverContractBalance = usdc.balanceOf(ccipReceiverContract);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(prejoinModule));
        emit OnCouponRedeemed(couponUser, couponAmount);
        (uint256 feeToOp, ) = prejoinModule.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            couponUser,
            couponAmount
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(operator);
        uint256 finalCouponUserBalance = usdc.balanceOf(couponUser);
        uint256 finalCCIPReceiverContractBalance = usdc.balanceOf(ccipReceiverContract);

        // Coupon pool balance should decrease by the coupon amount
        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        // Operator balance should increase by the fee
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        // Coupon user balance should not change
        assertEq(finalCouponUserBalance, initialCouponUserBalance);
        // CCIP receiver contract balance should not change
        assertEq(finalCCIPReceiverContractBalance, initialCCIPReceiverContractBalance);
        assert(feeToOp > 0);

        (uint256 contributionBeforeFee, , , uint256 discount) = prejoinModule.getPrepaidMember(
            couponUser
        );

        assertEq(contributionBeforeFee, couponAmount);
        assertEq(discount, 0); // No discount as the coupon is consumed completely and covers the whole membership
    }

    //======== coupon equals than contribution ========//
    function testCouponPrepaymentNoCcipCase2() public setCouponPoolAndCouponRedeemer {
        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(operator);
        uint256 initialCouponUserBalance = usdc.balanceOf(couponUser);
        uint256 initialCCIPReceiverContractBalance = usdc.balanceOf(ccipReceiverContract);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(prejoinModule));
        emit OnCouponRedeemed(couponUser, couponAmount);
        (uint256 feeToOp, ) = prejoinModule.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            couponUser,
            couponAmount
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(operator);
        uint256 finalCouponUserBalance = usdc.balanceOf(couponUser);
        uint256 finalCCIPReceiverContractBalance = usdc.balanceOf(ccipReceiverContract);

        // Coupon pool balance should decrease by the coupon amount
        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        // Operator balance should increase by the fee
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        // Coupon user balance should not change
        assertEq(finalCouponUserBalance, initialCouponUserBalance);
        // CCIP receiver contract balance should not change
        assertEq(finalCCIPReceiverContractBalance, initialCCIPReceiverContractBalance);
        assert(feeToOp > 0);

        (uint256 contributionBeforeFee, , , uint256 discount) = prejoinModule.getPrepaidMember(
            couponUser
        );

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT);
        assertEq(discount, 0); // No discount as the coupon is consumed completely and covers the whole membership
    }

    //======== coupon less than contribution ========//
    function testCouponPrepaymentNoCcipCase3() public setCouponPoolAndCouponRedeemer {
        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(operator);
        uint256 initialCouponUserBalance = usdc.balanceOf(couponUser);
        uint256 initialCCIPReceiverContractBalance = usdc.balanceOf(ccipReceiverContract);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(prejoinModule));
        emit OnCouponRedeemed(couponUser, couponAmount);
        (uint256 feeToOp, ) = prejoinModule.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT * 2,
            address(0),
            couponUser,
            couponAmount
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(operator);
        uint256 finalCouponUserBalance = usdc.balanceOf(couponUser);
        uint256 finalCCIPReceiverContractBalance = usdc.balanceOf(ccipReceiverContract);

        // Coupon pool balance should decrease by the coupon amount
        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        // Operator balance should increase by the fee
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        // Coupon user balance should decrease by the contribution minus the coupon minus the discount
        assertEq(
            finalCouponUserBalance,
            initialCouponUserBalance -
                (CONTRIBUTION_AMOUNT -
                    ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100))
        );
        // CCIP receiver contract balance should not change
        assertEq(finalCCIPReceiverContractBalance, initialCCIPReceiverContractBalance);
        assert(feeToOp > 0);

        (uint256 contributionBeforeFee, , , uint256 discount) = prejoinModule.getPrepaidMember(
            couponUser
        );

        uint256 expectedDiscount = (((CONTRIBUTION_AMOUNT * 2) - couponAmount) *
            CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100;

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT * 2);
        assertEq(discount, expectedDiscount); // Applied to what is left after the coupon
    }

    //======== no coupon ========//
    function testCouponPrepaymentNoCcipCase4() public setCouponPoolAndCouponRedeemer {
        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(operator);
        uint256 initialCouponUserBalance = usdc.balanceOf(couponUser);
        uint256 initialCCIPReceiverContractBalance = usdc.balanceOf(ccipReceiverContract);

        vm.prank(couponRedeemer);
        (uint256 feeToOp, uint256 discount) = prejoinModule.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            couponUser,
            0
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(operator);
        uint256 finalCouponUserBalance = usdc.balanceOf(couponUser);
        uint256 finalCCIPReceiverContractBalance = usdc.balanceOf(ccipReceiverContract);

        // Coupon pool balance should not change
        assertEq(finalCouponPoolBalance, initialCouponPoolBalance);
        // Operator balance should increase by the fee
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        // Coupon user balance should decrease by the contribution minus the discount
        assertEq(
            finalCouponUserBalance,
            initialCouponUserBalance -
                (CONTRIBUTION_AMOUNT -
                    ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100))
        );
        // CCIP receiver contract balance should not change
        assertEq(finalCCIPReceiverContractBalance, initialCCIPReceiverContractBalance);

        assert(feeToOp > 0);
        assert(discount > 0);
    }

    /*//////////////////////////////////////////////////////////////
                      COUPON PREPAYMENTS WITH CCIP
    //////////////////////////////////////////////////////////////*/

    //======== coupon higher than contribution ========//
    function testCouponPrepaymentWithCcipCase1()
        public
        setCouponPoolAndCouponRedeemer
        setCcipReceiverContract
    {
        uint256 couponAmount = CONTRIBUTION_AMOUNT * 2;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(operator);
        uint256 initialCouponUserBalance = usdc.balanceOf(couponUser);
        uint256 initialCCIPReceiverContractBalance = usdc.balanceOf(ccipReceiverContract);

        vm.prank(ccipReceiverContract);
        vm.expectEmit(true, true, true, false, address(prejoinModule));
        emit OnCouponRedeemed(couponUser, couponAmount);
        (uint256 feeToOp, ) = prejoinModule.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            couponUser,
            couponAmount
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(operator);
        uint256 finalCouponUserBalance = usdc.balanceOf(couponUser);
        uint256 finalCCIPReceiverContractBalance = usdc.balanceOf(ccipReceiverContract);

        // Coupon pool balance should decrease by the coupon amount
        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        // Operator balance should increase by the fee
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        // Coupon user balance should not change
        assertEq(finalCouponUserBalance, initialCouponUserBalance);
        // CCIP receiver contract balance should not change
        assertEq(finalCCIPReceiverContractBalance, initialCCIPReceiverContractBalance);
        assert(feeToOp > 0);

        (uint256 contributionBeforeFee, , , uint256 discount) = prejoinModule.getPrepaidMember(
            couponUser
        );

        assertEq(contributionBeforeFee, couponAmount);
        assertEq(discount, 0); // No discount as the coupon is consumed completely and covers the whole membership
    }

    //======== coupon equals than contribution ========//
    function testCouponPrepaymentWithCcipCase2()
        public
        setCouponPoolAndCouponRedeemer
        setCcipReceiverContract
    {
        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(operator);
        uint256 initialCouponUserBalance = usdc.balanceOf(couponUser);
        uint256 initialCCIPReceiverContractBalance = usdc.balanceOf(ccipReceiverContract);

        vm.prank(ccipReceiverContract);
        vm.expectEmit(true, true, true, false, address(prejoinModule));
        emit OnCouponRedeemed(couponUser, couponAmount);
        (uint256 feeToOp, ) = prejoinModule.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            couponUser,
            couponAmount
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(operator);
        uint256 finalCouponUserBalance = usdc.balanceOf(couponUser);
        uint256 finalCCIPReceiverContractBalance = usdc.balanceOf(ccipReceiverContract);

        // Coupon pool balance should decrease by the coupon amount
        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        // Operator balance should increase by the fee
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        // Coupon user balance should not change
        assertEq(finalCouponUserBalance, initialCouponUserBalance);
        // CCIP receiver contract balance should not change
        assertEq(finalCCIPReceiverContractBalance, initialCCIPReceiverContractBalance);
        assert(feeToOp > 0);

        (uint256 contributionBeforeFee, , , uint256 discount) = prejoinModule.getPrepaidMember(
            couponUser
        );

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT);
        assertEq(discount, 0); // No discount as the coupon is consumed completely and covers the whole membership
    }

    //======== coupon less than contribution ========//
    function testCouponPrepaymentWithCcipCase3()
        public
        setCouponPoolAndCouponRedeemer
        setCcipReceiverContract
    {
        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(operator);
        uint256 initialCouponUserBalance = usdc.balanceOf(couponUser);
        uint256 initialCCIPReceiverContractBalance = usdc.balanceOf(ccipReceiverContract);

        vm.prank(ccipReceiverContract);
        vm.expectEmit(true, true, true, false, address(prejoinModule));
        emit OnCouponRedeemed(couponUser, couponAmount);
        (uint256 feeToOp, ) = prejoinModule.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT * 2,
            address(0),
            couponUser,
            couponAmount
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(operator);
        uint256 finalCouponUserBalance = usdc.balanceOf(couponUser);
        uint256 finalCCIPReceiverContractBalance = usdc.balanceOf(ccipReceiverContract);

        // Coupon pool balance should decrease by the coupon amount
        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);
        // Operator balance should increase by the fee
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        // Coupon user balance should not change
        assertEq(finalCouponUserBalance, initialCouponUserBalance);
        // CCIP receiver balance should decrease by the contribution minus the coupon minus the discount
        assertEq(
            finalCCIPReceiverContractBalance,
            initialCCIPReceiverContractBalance -
                (CONTRIBUTION_AMOUNT -
                    ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100))
        );
        assert(feeToOp > 0);

        (uint256 contributionBeforeFee, , , uint256 discount) = prejoinModule.getPrepaidMember(
            couponUser
        );

        uint256 expectedDiscount = (((CONTRIBUTION_AMOUNT * 2) - couponAmount) *
            CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100;

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT * 2);
        assertEq(discount, expectedDiscount); // Applied to what is left after the coupon
    }

    //======== no coupon ========//
    function testCouponPrepaymentWithCcipCase4()
        public
        setCouponPoolAndCouponRedeemer
        setCcipReceiverContract
    {
        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 initialOperatorBalance = usdc.balanceOf(operator);
        uint256 initialCouponUserBalance = usdc.balanceOf(couponUser);
        uint256 initialCCIPReceiverContractBalance = usdc.balanceOf(ccipReceiverContract);

        vm.prank(ccipReceiverContract);
        (uint256 feeToOp, uint256 discount) = prejoinModule.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            couponUser,
            0
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);
        uint256 finalOperatorBalance = usdc.balanceOf(operator);
        uint256 finalCouponUserBalance = usdc.balanceOf(couponUser);
        uint256 finalCCIPReceiverContractBalance = usdc.balanceOf(ccipReceiverContract);

        // Coupon pool balance should not change
        assertEq(finalCouponPoolBalance, initialCouponPoolBalance);
        // Operator balance should increase by the fee
        assertEq(finalOperatorBalance, initialOperatorBalance + feeToOp);
        // Coupon user balance should not change
        assertEq(finalCouponUserBalance, initialCouponUserBalance);
        // CCIP receiver balance should decrease by the contribution minus minus the discount
        assertEq(
            finalCCIPReceiverContractBalance,
            initialCCIPReceiverContractBalance -
                (CONTRIBUTION_AMOUNT -
                    ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100))
        );

        assert(feeToOp > 0);
        assert(discount > 0);
    }
}
