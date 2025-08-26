// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ReferralGatewayPaymentRevertsTest is Test {
    TestDeployProtocol deployer;
    ReferralGateway referralGateway;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address referralGatewayAddress;
    address takadao;
    address pauseGuardian;
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

    modifier pauseContract() {
        vm.prank(pauseGuardian);
        referralGateway.pause();
        _;
    }

    function setUp() public {
        // Deployer
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (, referralGatewayAddress, , , , , , usdcAddress, , helperConfig) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        pauseGuardian = config.pauseGuardian;

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

    function testMustRevertIfPrepaymentContributionIsOutOfRange() public {
        // 24.99 USDC
        vm.startPrank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__InvalidContribution.selector);
        referralGateway.payContributionOnBehalfOf(2499e4, nonKycParent, child, 0, false);

        // 250.01 USDC
        vm.expectRevert(ReferralGateway.ReferralGateway__InvalidContribution.selector);
        referralGateway.payContributionOnBehalfOf(25001e4, nonKycParent, child, 0, false);
        vm.stopPrank();
    }

    function testMustRevertIfCouponIsOutOfRange() public {
        // 24.99 USDC
        vm.startPrank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__InvalidContribution.selector);
        referralGateway.payContributionOnBehalfOf(
            USDC_INITIAL_AMOUNT,
            nonKycParent,
            child,
            249e4,
            false
        );

        // 250.01 USDC
        vm.expectRevert(ReferralGateway.ReferralGateway__InvalidContribution.selector);
        referralGateway.payContributionOnBehalfOf(
            USDC_INITIAL_AMOUNT,
            nonKycParent,
            child,
            25001e4,
            false
        );
        vm.stopPrank();
    }

    function testMustRevertIfDonatedIsTrueAndContributionIsGreaterThan25() public {
        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__InvalidContribution.selector);
        referralGateway.payContributionOnBehalfOf(USDC_INITIAL_AMOUNT, address(0), child, 0, true);
    }

    function testMustRevertIfMemberIsZeroAddress() public {
        vm.startPrank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.payContributionOnBehalfOf(200e6, address(0), address(0), 0, false);
    }

    //======== preJoinEnabled = true, referralDiscount = true, invalid referral ========//
    function testPaymentRevertsIfParentIsInvalidCase1() public {
        (, , , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();

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

        (, , , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(totalCollectedFees, 0);
    }

    //======== preJoinEnabled = true, referralDiscount = false, invalid referral ========//
    function testPaymentRevertsIfParentIsInvalidCase2() public {
        vm.prank(takadao);
        referralGateway.switchReferralDiscount();

        (, , , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();

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

        (, , , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(totalCollectedFees, 0);
    }

    // ======== preJoinEnabled = true, referralDiscount = true ========//
    function testMustRevertIfTryToJoinTwiceCase1() public {
        vm.startPrank(couponRedeemer);
        // Child pays the contribution for the first time
        referralGateway.payContributionOnBehalfOf(USDC_INITIAL_AMOUNT, address(0), child, 0, false);

        // If try to pay again, it must revert
        vm.expectRevert(ReferralGateway.ReferralGateway__AlreadyMember.selector);
        referralGateway.payContributionOnBehalfOf(USDC_INITIAL_AMOUNT, address(0), child, 0, false);

        vm.stopPrank();
    }

    // ======== preJoinEnabled = true, referralDiscount = false ========//
    function testMustRevertIfTryToJoinTwiceCase2() public {
        // We disable the referral discount
        vm.prank(takadao);
        referralGateway.switchReferralDiscount();

        vm.startPrank(couponRedeemer);
        // Child pays the contribution for the first time
        referralGateway.payContributionOnBehalfOf(USDC_INITIAL_AMOUNT, address(0), child, 0, false);

        // If try to pay again, it must revert
        vm.expectRevert(ReferralGateway.ReferralGateway__AlreadyMember.selector);
        referralGateway.payContributionOnBehalfOf(USDC_INITIAL_AMOUNT, address(0), child, 0, false);

        vm.stopPrank();
    }

    // ======== preJoinEnabled = false, referralDiscount = true ========//
    function testMustRevertIfTryToJoinTwiceCase3() public {
        // We disable the prejoin discount
        vm.prank(takadao);
        referralGateway.switchPrejoinDiscount();

        vm.startPrank(couponRedeemer);
        // Child pays the contribution for the first time
        referralGateway.payContributionOnBehalfOf(USDC_INITIAL_AMOUNT, address(0), child, 0, false);

        // If try to pay again, it must revert
        vm.expectRevert(ReferralGateway.ReferralGateway__AlreadyMember.selector);
        referralGateway.payContributionOnBehalfOf(USDC_INITIAL_AMOUNT, address(0), child, 0, false);

        vm.stopPrank();
    }

    // ======== preJoinEnabled = false, referralDiscount = false ========//
    function testMustRevertIfTryToJoinTwiceCase4() public {
        // We disable the prejoin discount and referral discount
        vm.startPrank(takadao);
        referralGateway.switchPrejoinDiscount();

        referralGateway.switchReferralDiscount();
        vm.stopPrank();

        vm.startPrank(couponRedeemer);
        // Child pays the contribution for the first time
        referralGateway.payContributionOnBehalfOf(USDC_INITIAL_AMOUNT, address(0), child, 0, false);

        // If try to pay again, it must revert
        vm.expectRevert(ReferralGateway.ReferralGateway__AlreadyMember.selector);
        referralGateway.payContributionOnBehalfOf(USDC_INITIAL_AMOUNT, address(0), child, 0, false);

        vm.stopPrank();
    }

    function testMustRevertIfCouponIsGreaterThanContribution() public {
        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__InvalidContribution.selector);
        referralGateway.payContributionOnBehalfOf(
            USDC_INITIAL_AMOUNT,
            address(0),
            child,
            USDC_INITIAL_AMOUNT * 2,
            false
        );
    }

    function testMustRevertIfContractIsPaused() public pauseContract {
        vm.prank(couponRedeemer);
        vm.expectRevert();
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, address(0), child, 0, false);
    }
}
