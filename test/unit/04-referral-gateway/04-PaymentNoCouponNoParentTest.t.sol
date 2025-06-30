// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ReferralGatewayNoCouponNoParentPaymentTest is Test {
    TestDeployProtocol deployer;
    ReferralGateway referralGateway;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address referralGatewayAddress;
    address takadao;
    address nonKycParent = makeAddr("nonKycParent");
    address child = makeAddr("child");
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "The LifeDao";
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
        (
            ,
            bmConsumerMock,
            ,
            referralGatewayAddress,
            ,
            ,
            ,
            ,
            ,
            usdcAddress,
            ,
            helperConfig
        ) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;

        // Assign implementations
        referralGateway = ReferralGateway(referralGatewayAddress);
        usdc = IUSDC(usdcAddress);

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(referralGatewayAddress);

        // Give and approve USDC
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);

        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);

        vm.startPrank(takadao);
        referralGateway.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        referralGateway.setDaoName(tDaoName);
        referralGateway.createDAO(true, true, 1743479999, 1e12);
        vm.stopPrank();
    }

    function testPrepaymentDonatedTrue() public {
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, address(0), child, 0, true);

        (uint256 contributionBeforeFee, , , ) = referralGateway.getPrepaidMember(child);

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT);
    }

    //======== preJoinEnabled = true, referralDiscount = true, no parent, no coupon ========//
    function testPrepaymentCase1() public {
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();

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

        (, , , uint256 discount) = referralGateway.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 2_500_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = true, referralDiscount = false, no parent, no coupon ========//
    function testPrepaymentCase2() public {
        vm.prank(takadao);
        referralGateway.switchReferralDiscount();

        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();

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

        (, , , uint256 discount) = referralGateway.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 3_750_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = false, referralDiscount = true, no parent, no coupon ========//
    function testPrepaymentCase3() public {
        vm.prank(takadao);
        referralGateway.setPrejoinDiscount(false);

        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();

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

        (, , , uint256 discount) = referralGateway.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 5_000_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = false, referralDiscount = false, no parent, no coupon ========//
    function testPrepaymentCase4() public {
        vm.prank(takadao);
        referralGateway.setPrejoinDiscount(false);

        vm.prank(takadao);
        referralGateway.switchReferralDiscount();

        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(alreadyCollectedFees, 0);

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees - ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = 0;

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(address(0), child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, address(0), child, 0, false);

        (, , , uint256 discount) = referralGateway.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 6_250_000);
        assertEq(discount, expectedDiscount);
    }
}
