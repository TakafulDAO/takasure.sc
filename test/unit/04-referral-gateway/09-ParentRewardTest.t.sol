// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ReferralGatewayParentRewardTest is Test {
    TestDeployProtocol deployer;
    ReferralGateway referralGateway;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address referralGatewayAddress;
    address takadao;
    address KYCProvider;
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "The LifeDao";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant LAYER_ONE_REWARD_RATIO = 4; // Layer one reward ratio 4%
    uint256 public constant LAYER_TWO_REWARD_RATIO = 1; // Layer two reward ratio 1%
    uint256 public constant LAYER_THREE_REWARD_RATIO = 35; // Layer three reward ratio 0.35%
    uint256 public constant LAYER_FOUR_REWARD_RATIO = 175; // Layer four reward ratio 0.175%

    event OnParentRewardTransferStatus(
        address indexed parent,
        uint256 indexed layer,
        address indexed child,
        uint256 reward,
        bool status
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
        KYCProvider = config.kycProvider;

        // Assign implementations
        referralGateway = ReferralGateway(referralGatewayAddress);
        usdc = IUSDC(usdcAddress);

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(referralGatewayAddress);

        vm.startPrank(takadao);
        referralGateway.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        referralGateway.createDAO(true, true, 1743479999, 1e12);
        vm.stopPrank();
    }

    function testCompleteReferralTreeAssignRewardCorrectly() public {
        // Parents addresses
        address parentTier1 = makeAddr("parentTier1");
        address parentTier2 = makeAddr("parentTier2");
        address parentTier3 = makeAddr("parentTier3");
        address parentTier4 = makeAddr("parentTier4");
        address[4] memory parents = [parentTier1, parentTier2, parentTier3, parentTier4];

        for (uint256 i = 0; i < parents.length; i++) {
            // Give USDC to parents
            deal(address(usdc), parents[i], 10 * CONTRIBUTION_AMOUNT);
            // Approve the contracts
            vm.startPrank(parents[i]);
            usdc.approve(address(referralGateway), 10 * CONTRIBUTION_AMOUNT);
            vm.stopPrank();
        }

        address childWithoutReferee = makeAddr("childWithoutReferee");
        deal(address(usdc), childWithoutReferee, 10 * CONTRIBUTION_AMOUNT);
        vm.prank(childWithoutReferee);
        usdc.approve(address(referralGateway), 10 * CONTRIBUTION_AMOUNT);

        // First Parent 1 becomes a member without a referral
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            parentTier1,
            0,
            false
        );
        vm.prank(KYCProvider);
        referralGateway.approveKYC(parentTier1);

        // Parent 2 prepay referred by parent 1
        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            parentTier2Contribution,
            parentTier1,
            parentTier2,
            0,
            false
        );

        // The expected parent 1 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentOneReward = (parentTier2Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        console2.log("expectedParentOneReward", expectedParentOneReward);

        vm.prank(KYCProvider);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewardTransferStatus(
            parentTier1,
            1,
            parentTier2,
            expectedParentOneReward,
            true
        );
        referralGateway.approveKYC(parentTier2);

        // Parent 3 prepay referred by parent 2
        uint256 parentTier3Contribution = 2 * CONTRIBUTION_AMOUNT;
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            parentTier3Contribution,
            parentTier2,
            parentTier3,
            0,
            false
        );

        // The expected parent 2 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentTwoReward = (parentTier3Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 1% of the parent 2 contribution
        expectedParentOneReward = (parentTier3Contribution * LAYER_TWO_REWARD_RATIO) / 100;

        vm.prank(KYCProvider);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewardTransferStatus(
            parentTier2,
            1,
            parentTier3,
            expectedParentTwoReward,
            true
        );
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewardTransferStatus(
            parentTier1,
            2,
            parentTier3,
            expectedParentOneReward,
            true
        );
        referralGateway.approveKYC(parentTier3);

        // Parent 4 prepay referred by parent 3
        uint256 parentTier4Contribution = 7 * CONTRIBUTION_AMOUNT;
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            parentTier4Contribution,
            parentTier3,
            parentTier4,
            0,
            false
        );

        // The expected parent 3 reward ratio will be 4% of the parent 4 contribution
        uint256 expectedParentThreeReward = (parentTier4Contribution * LAYER_ONE_REWARD_RATIO) /
            100;
        // The expected parent 2 reward ratio will be 1% of the parent 4 contribution
        expectedParentTwoReward = (parentTier4Contribution * LAYER_TWO_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 0.35% of the parent 4 contribution
        expectedParentOneReward = (parentTier4Contribution * LAYER_THREE_REWARD_RATIO) / 10000;

        vm.prank(KYCProvider);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewardTransferStatus(
            parentTier3,
            1,
            parentTier4,
            expectedParentThreeReward,
            true
        );
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewardTransferStatus(
            parentTier2,
            2,
            parentTier4,
            expectedParentTwoReward,
            true
        );
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewardTransferStatus(
            parentTier1,
            3,
            parentTier4,
            expectedParentOneReward,
            true
        );
        referralGateway.approveKYC(parentTier4);

        // Child without referee prepay referred by parent 4
        uint256 childWithoutRefereeContribution = 4 * CONTRIBUTION_AMOUNT;
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            childWithoutRefereeContribution,
            parentTier4,
            childWithoutReferee,
            0,
            false
        );

        // The expected parent 4 reward ratio will be 4% of the child without referee contribution
        uint256 expectedParentFourReward = (childWithoutRefereeContribution *
            LAYER_ONE_REWARD_RATIO) / 100;
        // The expected parent 3 reward ratio will be 1% of the child without referee
        expectedParentThreeReward =
            (childWithoutRefereeContribution * LAYER_TWO_REWARD_RATIO) /
            100;
        // The expected parent 2 reward ratio will be 0.35% of the child without referee contribution
        expectedParentTwoReward =
            (childWithoutRefereeContribution * LAYER_THREE_REWARD_RATIO) /
            10000;
        // The expected parent 1 reward ratio will be 0.175% of the child without referee contribution
        expectedParentOneReward =
            (childWithoutRefereeContribution * LAYER_FOUR_REWARD_RATIO) /
            100000;

        vm.prank(KYCProvider);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewardTransferStatus(
            parentTier4,
            1,
            childWithoutReferee,
            expectedParentFourReward,
            true
        );
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewardTransferStatus(
            parentTier3,
            2,
            childWithoutReferee,
            expectedParentThreeReward,
            true
        );
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewardTransferStatus(
            parentTier2,
            3,
            childWithoutReferee,
            expectedParentTwoReward,
            true
        );
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewardTransferStatus(
            parentTier1,
            4,
            childWithoutReferee,
            expectedParentOneReward,
            true
        );
        referralGateway.approveKYC(childWithoutReferee);
    }

    function testLayersCorrectlyAssigned() public {
        // Parents addresses
        address parentTier1 = makeAddr("parentTier1");
        address parentTier2 = makeAddr("parentTier2");
        address parentTier3 = makeAddr("parentTier3");
        address parentTier4 = makeAddr("parentTier4");
        address[4] memory parents = [parentTier1, parentTier2, parentTier3, parentTier4];
        for (uint256 i = 0; i < parents.length; i++) {
            // Give USDC to parents
            deal(address(usdc), parents[i], 10 * CONTRIBUTION_AMOUNT);
            // Approve the contracts
            vm.startPrank(parents[i]);
            usdc.approve(address(referralGateway), 10 * CONTRIBUTION_AMOUNT);
            vm.stopPrank();
        }
        address childWithoutReferee = makeAddr("childWithoutReferee");

        deal(address(usdc), childWithoutReferee, 10 * CONTRIBUTION_AMOUNT);
        vm.prank(childWithoutReferee);
        usdc.approve(address(referralGateway), 10 * CONTRIBUTION_AMOUNT);

        // First Parent 1 becomes a member without a referral
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            parentTier1,
            0,
            false
        );

        vm.prank(KYCProvider);
        referralGateway.approveKYC(parentTier1);

        // Now parent 1 refer parent 2, this refer parent 3, this refer parent 4 and this refer the child

        // Parent 2 prepay referred by parent 1
        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;

        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            parentTier2Contribution,
            parentTier1,
            parentTier2,
            0,
            false
        );

        // The expected parent 1 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentOneReward = (parentTier2Contribution * LAYER_ONE_REWARD_RATIO) / 100;

        assertEq(
            referralGateway.getParentRewardsByChild(parentTier1, parentTier2),
            expectedParentOneReward
        );
        assertEq(referralGateway.getParentRewardsByLayer(parentTier1, 1), expectedParentOneReward);

        // Parent 3 prepay referred by parent 2
        vm.prank(KYCProvider);
        referralGateway.approveKYC(parentTier2);

        uint256 parentTier3Contribution = 2 * CONTRIBUTION_AMOUNT;
        // The expected parent 2 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentTwoReward = (parentTier3Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 1% of the parent 2 contribution
        expectedParentOneReward = (parentTier3Contribution * LAYER_TWO_REWARD_RATIO) / 100;

        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            parentTier3Contribution,
            parentTier2,
            parentTier3,
            0,
            false
        );

        assertEq(
            referralGateway.getParentRewardsByChild(parentTier2, parentTier3),
            expectedParentTwoReward
        );
        assertEq(referralGateway.getParentRewardsByLayer(parentTier2, 1), expectedParentTwoReward);
        assertEq(referralGateway.getParentRewardsByLayer(parentTier1, 2), expectedParentOneReward);

        // Parent 4 prepay referred by parent 3
        vm.prank(KYCProvider);
        referralGateway.approveKYC(parentTier3);

        uint256 parentTier4Contribution = 7 * CONTRIBUTION_AMOUNT;
        // The expected parent 3 reward ratio will be 4% of the parent 4 contribution
        uint256 expectedParentThreeReward = (parentTier4Contribution * LAYER_ONE_REWARD_RATIO) /
            100;
        // The expected parent 2 reward ratio will be 1% of the parent 4 contribution
        expectedParentTwoReward = (parentTier4Contribution * LAYER_TWO_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 0.35% of the parent 4 contribution
        expectedParentOneReward = (parentTier4Contribution * LAYER_THREE_REWARD_RATIO) / 10000;

        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            parentTier4Contribution,
            parentTier3,
            parentTier4,
            0,
            false
        );

        assertEq(
            referralGateway.getParentRewardsByChild(parentTier3, parentTier4),
            expectedParentThreeReward
        );
        assertEq(
            referralGateway.getParentRewardsByLayer(parentTier3, 1),
            expectedParentThreeReward
        );
        assertEq(referralGateway.getParentRewardsByLayer(parentTier2, 2), expectedParentTwoReward);
        assertEq(referralGateway.getParentRewardsByLayer(parentTier1, 3), expectedParentOneReward);

        // Child without referee prepay referred by parent 4
        vm.prank(KYCProvider);
        referralGateway.approveKYC(parentTier4);

        // The expected parent 4 reward ratio will be 4% of the child without referee contribution
        uint256 expectedParentFourReward = (CONTRIBUTION_AMOUNT * LAYER_ONE_REWARD_RATIO) / 100;
        // The expected parent 3 reward ratio will be 1% of the child without referee
        expectedParentThreeReward = (CONTRIBUTION_AMOUNT * LAYER_TWO_REWARD_RATIO) / 100;
        // The expected parent 2 reward ratio will be 0.35% of the child without referee contribution
        expectedParentTwoReward = (CONTRIBUTION_AMOUNT * LAYER_THREE_REWARD_RATIO) / 10000;
        // The expected parent 1 reward ratio will be 0.175% of the child without referee contribution
        expectedParentOneReward = (CONTRIBUTION_AMOUNT * LAYER_FOUR_REWARD_RATIO) / 100000;

        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            parentTier4,
            childWithoutReferee,
            0,
            false
        );

        assertEq(
            referralGateway.getParentRewardsByChild(parentTier4, childWithoutReferee),
            expectedParentFourReward
        );
        assertEq(referralGateway.getParentRewardsByLayer(parentTier4, 1), expectedParentFourReward);
        assertEq(
            referralGateway.getParentRewardsByLayer(parentTier3, 2),
            expectedParentThreeReward
        );
        assertEq(referralGateway.getParentRewardsByLayer(parentTier2, 3), expectedParentTwoReward);
        assertEq(referralGateway.getParentRewardsByLayer(parentTier1, 4), expectedParentOneReward);
    }

    // Rewards are distributed correctly for those who had referrals before referral discount was disabled
    function testCompleteReferralTreeAssignRewardCorrectlyBeforeDisableReferralDiscount() public {
        // Parents addresses
        address parentTier1 = makeAddr("parentTier1");
        address parentTier2 = makeAddr("parentTier2");
        address parentTier3 = makeAddr("parentTier3");
        address parentTier4 = makeAddr("parentTier4");
        address[4] memory parents = [parentTier1, parentTier2, parentTier3, parentTier4];

        for (uint256 i = 0; i < parents.length; i++) {
            // Give USDC to parents
            deal(address(usdc), parents[i], 10 * CONTRIBUTION_AMOUNT);
            // Approve the contracts
            vm.startPrank(parents[i]);
            usdc.approve(address(referralGateway), 10 * CONTRIBUTION_AMOUNT);
            vm.stopPrank();
        }

        address childWithoutReferee = makeAddr("childWithoutReferee");
        deal(address(usdc), childWithoutReferee, 10 * CONTRIBUTION_AMOUNT);
        vm.prank(childWithoutReferee);
        usdc.approve(address(referralGateway), 10 * CONTRIBUTION_AMOUNT);

        // First Parent 1 becomes a member without a referral
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            parentTier1,
            0,
            false
        );
        vm.prank(KYCProvider);
        referralGateway.approveKYC(parentTier1);

        // Parent 2 prepay referred by parent 1
        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            parentTier2Contribution,
            parentTier1,
            parentTier2,
            0,
            false
        );

        // The expected parent 1 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentOneReward = (parentTier2Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        console2.log("expectedParentOneReward", expectedParentOneReward);

        vm.prank(KYCProvider);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewardTransferStatus(
            parentTier1,
            1,
            parentTier2,
            expectedParentOneReward,
            true
        );
        referralGateway.approveKYC(parentTier2);

        // Parent 3 prepay referred by parent 2
        uint256 parentTier3Contribution = 2 * CONTRIBUTION_AMOUNT;
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            parentTier3Contribution,
            parentTier2,
            parentTier3,
            0,
            false
        );

        // The expected parent 2 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentTwoReward = (parentTier3Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 1% of the parent 2 contribution
        expectedParentOneReward = (parentTier3Contribution * LAYER_TWO_REWARD_RATIO) / 100;

        // Disable the referral discount, before approving KYC for parent 3
        // This means that the parent 2 will have the rewards from parent 3 contribution,
        // But parent 3 won't have any rewards from his children contributions

        vm.prank(takadao);
        referralGateway.switchRewardsDistribution();

        vm.prank(KYCProvider);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewardTransferStatus(
            parentTier2,
            1,
            parentTier3,
            expectedParentTwoReward,
            true
        );
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewardTransferStatus(
            parentTier1,
            2,
            parentTier3,
            expectedParentOneReward,
            true
        );
        referralGateway.approveKYC(parentTier3);

        uint256 parentTier4Contribution = 7 * CONTRIBUTION_AMOUNT;
        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__IncompatibleSettings.selector);
        referralGateway.payContributionOnBehalfOf(
            parentTier4Contribution,
            parentTier3,
            parentTier4,
            0,
            false
        );
    }
}
