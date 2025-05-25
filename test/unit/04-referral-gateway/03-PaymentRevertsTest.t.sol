// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasureReserve} from "test/utils/TestDeployTakasureReserve.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ReferralGatewayPaymentRevertsTest is Test {
    TestDeployTakasureReserve deployer;
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
        deployer = new TestDeployTakasureReserve();
        // Deploy contracts
        (, bmConsumerMock, , , , , , referralGatewayAddress, usdcAddress, , helperConfig) = deployer
            .run();

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
        referralGateway.createDAO(true, true, 1743479999, 1e12, address(bmConsumerMock));
        vm.stopPrank();
    }

    function testMustRevertIfprepaymentContributionIsOutOfRange() public {
        // 24.99 USDC
        vm.startPrank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__InvalidContribution.selector);
        referralGateway.payContributionOnBehalfOf(2499e4, nonKycParent, child, 0, false);

        // 250.01 USDC
        vm.expectRevert(ReferralGateway.ReferralGateway__InvalidContribution.selector);
        referralGateway.payContributionOnBehalfOf(25001e4, nonKycParent, child, 0, false);
        vm.stopPrank();
    }

    //======== preJoinEnabled = true, referralDiscount = true, invalid referral ========//
    function testPaymentRevertsIfParentIsInvalidCase1() public {
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(alreadyCollectedFees, 0);

        address nonKYCParent = makeAddr("nonKYCParent");

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__ParentMustKYCFirst.selector);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            nonKYCParent,
            child,
            0,
            false
        );

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(totalCollectedFees, 0);
    }

    //======== preJoinEnabled = true, referralDiscount = false, invalid referral ========//
    function testPaymentRevertsIfParentIsInvalidCase2() public {
        vm.prank(takadao);
        referralGateway.switchReferralDiscount();

        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(alreadyCollectedFees, 0);

        address nonKYCParent = makeAddr("nonKYCParent");

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__ParentMustKYCFirst.selector);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            nonKYCParent,
            child,
            0,
            false
        );

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(totalCollectedFees, 0);
    }
}
