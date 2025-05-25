// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasureReserve} from "test/utils/TestDeployTakasureReserve.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract ReferralGatewayTest is Test, SimulateDonResponse {
    TestDeployTakasureReserve deployer;
    ReferralGateway referralGateway;
    TakasureReserve takasureReserve;
    EntryModule entryModule;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address referralGatewayAddress;
    address takasureReserveAddress;
    address entryModuleAddress;
    address takadao;
    address daoAdmin;
    address KYCProvider;
    address pauseGuardian;
    address referral = makeAddr("referral");
    address member = makeAddr("member");
    address notMember = makeAddr("notMember");
    address child = makeAddr("child");
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "The LifeDao";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant LAYER_ONE_REWARD_RATIO = 4; // Layer one reward ratio 4%
    uint256 public constant LAYER_TWO_REWARD_RATIO = 1; // Layer two reward ratio 1%
    uint256 public constant LAYER_THREE_REWARD_RATIO = 35; // Layer three reward ratio 0.35%
    uint256 public constant LAYER_FOUR_REWARD_RATIO = 175; // Layer four reward ratio 0.175%
    uint8 public constant SERVICE_FEE_RATIO = 27;
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee
    uint256 public constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution deducted from contribution
    uint256 public constant REFERRAL_RESERVE = 5; // 5% of contribution TO Referral Reserve
    uint256 public constant REPOOL_FEE_RATIO = 2; // 2% of contribution deducted from fee

    bytes32 public constant REFERRAL = keccak256("REFERRAL");

    struct PrepaidMember {
        string tDAOName;
        address member;
        uint256 contributionBeforeFee;
        uint256 contributionAfterFee;
        uint256 finalFee; // Fee after all the discounts and rewards
        uint256 discount;
    }

    event OnPreJoinEnabledChanged(bool indexed isPreJoinEnabled);
    event OnNewReferralProposal(address indexed proposedReferral);
    event OnNewReferral(address indexed referral);
    event OnPrepayment(
        address indexed parent,
        address indexed child,
        uint256 indexed contribution,
        uint256 fee,
        uint256 discount
    );
    event OnMemberJoined(uint256 indexed memberId, address indexed member);
    event OnNewDaoCreated(string indexed daoName);
    event OnParentRewardTransferStatus(
        address indexed parent,
        uint256 indexed layer,
        address indexed child,
        uint256 reward,
        bool status
    );
    event OnBenefitMultiplierConsumerChanged(
        address indexed newBenefitMultiplierConsumer,
        address indexed oldBenefitMultiplierConsumer
    );

    function setUp() public {
        // Deployer
        deployer = new TestDeployTakasureReserve();
        // Deploy contracts
        (
            ,
            bmConsumerMock,
            takasureReserveAddress,
            entryModuleAddress,
            ,
            ,
            ,
            referralGatewayAddress,
            usdcAddress,
            ,
            helperConfig
        ) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        daoAdmin = config.daoMultisig;
        KYCProvider = config.kycProvider;
        pauseGuardian = config.pauseGuardian;

        // Assign implementations
        referralGateway = ReferralGateway(referralGatewayAddress);
        takasureReserve = TakasureReserve(takasureReserveAddress);
        entryModule = EntryModule(entryModuleAddress);
        usdc = IUSDC(usdcAddress);

        // Config mocks
        vm.prank(daoAdmin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(takasureReserve));
        bmConsumerMock.setNewRequester(referralGatewayAddress);

        // Give and approve USDC
        deal(address(usdc), referral, USDC_INITIAL_AMOUNT);
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);
        deal(address(usdc), member, USDC_INITIAL_AMOUNT);

        vm.prank(referral);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);
        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);
        vm.prank(member);
        usdc.approve(address(takasureReserve), USDC_INITIAL_AMOUNT);
    }

    modifier setCouponRedeemer() {
        vm.prank(takadao);
        referralGateway.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CREATE DAO
    //////////////////////////////////////////////////////////////*/
    function testCreateANewDao() public {
        vm.prank(referral);
        vm.expectRevert();
        referralGateway.createDAO(
            true,
            true,
            (block.timestamp + 31_536_000),
            100e6,
            address(bmConsumerMock)
        );

        vm.prank(takadao);
        referralGateway.createDAO(
            true,
            true,
            (block.timestamp + 31_536_000),
            100e6,
            address(bmConsumerMock)
        );

        (
            bool prejoinEnabled,
            ,
            address DAOAdmin,
            address DAOAddress,
            uint256 launchDate,
            uint256 objectiveAmount,
            uint256 currentAmount,
            ,
            ,
            ,

        ) = referralGateway.getDAOData();

        assertEq(prejoinEnabled, true);
        assertEq(DAOAdmin, daoAdmin);
        assertEq(DAOAddress, address(0));
        assertEq(launchDate, block.timestamp + 31_536_000);
        assertEq(objectiveAmount, 100e6);
        assertEq(currentAmount, 0);

        vm.prank(takadao);
        vm.expectRevert(ReferralGateway.ReferralGateway__InvalidLaunchDate.selector);
        referralGateway.createDAO(true, true, 0, 100e6, address(bmConsumerMock));

        vm.prank(referral);
        vm.expectRevert();
        referralGateway.updateLaunchDate(block.timestamp + 32_000_000);

        vm.prank(daoAdmin);
        referralGateway.updateLaunchDate(block.timestamp + 32_000_000);
    }

    modifier createDao() {
        vm.startPrank(takadao);
        referralGateway.setDaoName(tDaoName);
        referralGateway.createDAO(true, true, 1743479999, 1e12, address(bmConsumerMock));
        vm.stopPrank();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                   LAUNCH DAO
        //////////////////////////////////////////////////////////////*/

    function testLaunchDAO() public createDao {
        (
            bool prejoinEnabled,
            bool referralDiscount,
            address DAOAdmin,
            address DAOAddress,
            uint256 launchDate,
            uint256 objectiveAmount,
            uint256 currentAmount,
            ,
            address rePoolAddress,
            ,

        ) = referralGateway.getDAOData();

        assertEq(DAOAddress, address(0));
        assertEq(prejoinEnabled, true);
        assertEq(referralDiscount, true);

        vm.prank(referral);
        vm.expectRevert();
        referralGateway.launchDAO(address(takasureReserve), true);

        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.launchDAO(address(0), true);

        vm.prank(daoAdmin);
        referralGateway.launchDAO(address(takasureReserve), true);

        (
            prejoinEnabled,
            referralDiscount,
            DAOAdmin,
            DAOAddress,
            launchDate,
            objectiveAmount,
            currentAmount,
            ,
            rePoolAddress,
            ,

        ) = referralGateway.getDAOData();

        assertEq(DAOAddress, address(takasureReserve));
        assert(!prejoinEnabled);
        assert(referralDiscount);
        assertEq(rePoolAddress, address(0));

        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__DAOAlreadyLaunched.selector);
        referralGateway.updateLaunchDate(block.timestamp + 32_000_000);

        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__DAOAlreadyLaunched.selector);
        referralGateway.launchDAO(address(takasureReserve), true);

        vm.prank(daoAdmin);
        referralGateway.switchReferralDiscount();

        (, referralDiscount, , , , , , , , , ) = referralGateway.getDAOData();

        assert(!referralDiscount);

        address newRePoolAddress = makeAddr("rePoolAddress");

        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.enableRepool(address(0));

        vm.prank(daoAdmin);
        referralGateway.enableRepool(newRePoolAddress);

        (, , , , , , , , rePoolAddress, , ) = referralGateway.getDAOData();

        assertEq(rePoolAddress, newRePoolAddress);
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    function testMustRevertIfprepaymentContributionIsOutOfRange()
        public
        setCouponRedeemer
        createDao
    {
        // 24.99 USDC
        vm.startPrank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__InvalidContribution.selector);
        referralGateway.payContributionOnBehalfOf(2499e4, referral, child, 0, false);

        // 250.01 USDC
        vm.expectRevert(ReferralGateway.ReferralGateway__InvalidContribution.selector);
        referralGateway.payContributionOnBehalfOf(25001e4, referral, child, 0, false);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                    PREPAYS
        //////////////////////////////////////////////////////////////*/

    //======== preJoinEnabled = true, referralDiscount = true, no referral ========//
    function testprepaymentCase1() public setCouponRedeemer createDao {
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

    //======== preJoinEnabled = true, referralDiscount = true, invalid referral ========//
    function testprepaymentCase2() public setCouponRedeemer createDao {
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(alreadyCollectedFees, 0);

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__ParentMustKYCFirst.selector);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, referral, child, 0, false);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(totalCollectedFees, 0);
    }

    //======== preJoinEnabled = true, referralDiscount = false, no referral ========//
    function testprepaymentCase3() public setCouponRedeemer createDao {
        vm.prank(daoAdmin);
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

    //======== preJoinEnabled = true, referralDiscount = false, invalid referral ========//
    function testprepaymentCase4() public setCouponRedeemer createDao {
        vm.prank(daoAdmin);
        referralGateway.switchReferralDiscount();

        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(alreadyCollectedFees, 0);

        vm.prank(couponRedeemer);
        vm.expectRevert(ReferralGateway.ReferralGateway__ParentMustKYCFirst.selector);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, referral, child, 0, false);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(totalCollectedFees, 0);
    }

    modifier referralPrepays() {
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            referral,
            0,
            false
        );
        _;
    }

    function testKYCAnAddress() public setCouponRedeemer createDao referralPrepays {
        vm.prank(KYCProvider);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.approveKYC(address(0));

        assert(!referralGateway.isMemberKYCed(referral));

        vm.prank(KYCProvider);
        referralGateway.approveKYC(referral);
        assert(referralGateway.isMemberKYCed(referral));
    }

    function testMustRevertIfKYCTwiceSameAddress()
        public
        setCouponRedeemer
        createDao
        referralPrepays
    {
        vm.startPrank(KYCProvider);
        referralGateway.approveKYC(referral);

        vm.expectRevert(ReferralGateway.ReferralGateway__MemberAlreadyKYCed.selector);
        referralGateway.approveKYC(referral);
        vm.stopPrank();
    }

    modifier KYCReferral() {
        vm.prank(KYCProvider);
        referralGateway.approveKYC(referral);
        _;
    }

    //======== preJoinEnabled = true, referralDiscount = true, valid referral ========//
    function testprepaymentCase5() public setCouponRedeemer createDao referralPrepays KYCReferral {
        // Already collected fees with the modifiers logic
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(alreadyCollectedFees, 2_500_000);

        uint256 expectedParentReward = (CONTRIBUTION_AMOUNT * LAYER_ONE_REWARD_RATIO) / 100;

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REFERRAL_RESERVE) / 100) -
            ((CONTRIBUTION_AMOUNT * REFERRAL_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100) + ((CONTRIBUTION_AMOUNT * REFERRAL_DISCOUNT_RATIO) / 100);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(referral, child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, referral, child, 0, false);

        (, , , uint256 discount) = referralGateway.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(collectedFees, 1_250_000);
        assertEq(totalCollectedFees, collectedFees + alreadyCollectedFees);
        assertEq(referralGateway.getParentRewardsByChild(referral, child), expectedParentReward);
        assertEq(expectedParentReward, 1_000_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = true, referralDiscount = false, valid referral ========//
    function testprepaymentCase6() public setCouponRedeemer createDao referralPrepays KYCReferral {
        vm.prank(daoAdmin);
        referralGateway.switchReferralDiscount();

        // Already collected fees with the modifiers logic
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData();
        assertEq(alreadyCollectedFees, 2_500_000);

        uint256 expectedParentReward = 0;

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100);

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(referral, child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, referral, child, 0, false);

        (, , , uint256 discount) = referralGateway.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData();

        assertEq(collectedFees, 3_750_000);
        assertEq(totalCollectedFees, collectedFees + alreadyCollectedFees);
        assertEq(referralGateway.getParentRewardsByChild(referral, child), expectedParentReward);
        assertEq(discount, expectedDiscount);
    }

    modifier referredPrepays() {
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, referral, child, 0, false);

        _;
    }

    modifier referredIsKYC() {
        vm.prank(KYCProvider);
        referralGateway.approveKYC(child);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                      JOIN
        //////////////////////////////////////////////////////////////*/

    function testMustRevertJoinPoolIfTheDaoHasNoAssignedAddressYet()
        public
        setCouponRedeemer
        createDao
        referralPrepays
        KYCReferral
    {
        vm.prank(referral);
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        emit OnMemberJoined(2, referral);
        referralGateway.joinDAO(referral);
    }

    function testMustRevertJoinPoolIfTheChildIsNotKYC()
        public
        setCouponRedeemer
        createDao
        referralPrepays
        KYCReferral
        referredPrepays
    {
        vm.prank(daoAdmin);
        referralGateway.launchDAO(address(takasureReserve), true);

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__NotKYCed.selector);
        emit OnMemberJoined(2, child);
        referralGateway.joinDAO(child);
    }

    /*//////////////////////////////////////////////////////////////
                                  GRANDPARENTS
        //////////////////////////////////////////////////////////////*/

    function testCompleteReferralTreeAssignRewardCorrectly() public setCouponRedeemer createDao {
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

    function testLayersCorrectlyAssigned() public setCouponRedeemer createDao {
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

    /*//////////////////////////////////////////////////////////////
                                     REPOOL
        //////////////////////////////////////////////////////////////*/

    function testTransferToRepool() public setCouponRedeemer createDao {
        address parentTier1 = makeAddr("parentTier1");
        address parentTier2 = makeAddr("parentTier2");
        address parentTier3 = makeAddr("parentTier3");
        address parentTier4 = makeAddr("parentTier4");
        address[4] memory parents = [parentTier1, parentTier2, parentTier3, parentTier4];

        for (uint256 i = 0; i < parents.length; i++) {
            deal(address(usdc), parents[i], 10 * CONTRIBUTION_AMOUNT);
            vm.startPrank(parents[i]);
            usdc.approve(address(referralGateway), 10 * CONTRIBUTION_AMOUNT);
            vm.stopPrank();
        }

        address childWithoutReferee = makeAddr("childWithoutReferee");
        deal(address(usdc), childWithoutReferee, 10 * CONTRIBUTION_AMOUNT);
        vm.prank(childWithoutReferee);
        usdc.approve(address(referralGateway), 10 * CONTRIBUTION_AMOUNT);

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

        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            parentTier2Contribution,
            parentTier1,
            parentTier2,
            0,
            false
        );

        vm.prank(KYCProvider);
        referralGateway.approveKYC(parentTier2);

        uint256 parentTier3Contribution = 2 * CONTRIBUTION_AMOUNT;
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            parentTier3Contribution,
            parentTier2,
            parentTier3,
            0,
            false
        );

        vm.prank(KYCProvider);
        referralGateway.approveKYC(parentTier3);

        uint256 parentTier4Contribution = 7 * CONTRIBUTION_AMOUNT;
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            parentTier4Contribution,
            parentTier3,
            parentTier4,
            0,
            false
        );

        vm.prank(KYCProvider);
        referralGateway.approveKYC(parentTier4);

        uint256 childWithoutRefereeContribution = 4 * CONTRIBUTION_AMOUNT;
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            childWithoutRefereeContribution,
            parentTier4,
            childWithoutReferee,
            0,
            false
        );

        vm.prank(KYCProvider);
        referralGateway.approveKYC(childWithoutReferee);

        vm.prank(daoAdmin);
        referralGateway.launchDAO(address(takasureReserve), true);

        address rePoolAddress = makeAddr("rePoolAddress");

        vm.prank(daoAdmin);
        referralGateway.enableRepool(rePoolAddress);

        (, , , , , , , , , uint256 toRepool, ) = referralGateway.getDAOData();

        assert(toRepool > 0);
        assertEq(usdc.balanceOf(rePoolAddress), 0);

        vm.prank(daoAdmin);
        referralGateway.transferToRepool();

        (, , , , , , , , , uint256 newRepoolBalance, ) = referralGateway.getDAOData();

        assertEq(newRepoolBalance, 0);
        assertEq(usdc.balanceOf(rePoolAddress), toRepool);
    }

    /*//////////////////////////////////////////////////////////////
                                    REFUNDS
        //////////////////////////////////////////////////////////////*/

    function testRefundContractHasEnoughBalance()
        public
        setCouponRedeemer
        createDao
        referralPrepays
        KYCReferral
        referredPrepays
        referredIsKYC
    {
        (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 feeToOperator,
            uint256 discount
        ) = referralGateway.getPrepaidMember(child);

        assert(contributionBeforeFee > 0);
        assert(contributionAfterFee > 0);
        assert(feeToOperator > 0);
        assert(discount > 0);
        assert(referralGateway.isMemberKYCed(child));

        vm.startPrank(child);
        // Should not be able to join because the DAO is not launched yet
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.joinDAO(child);

        // Should not be able to refund because the launched date is not reached yet
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.refundIfDAOIsNotLaunched(child);
        vm.stopPrank();

        (, , , , uint256 launchDate, , , , , , ) = referralGateway.getDAOData();

        vm.warp(launchDate);
        vm.roll(block.number + 1);

        vm.startPrank(child);
        // Should not be able to join because the DAO is not launched yet
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.joinDAO(child);

        // Should not be able to refund even if the launched date is reached, but has to wait 1 day
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.refundIfDAOIsNotLaunched(child);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        vm.startPrank(child);
        referralGateway.refundIfDAOIsNotLaunched(child);

        // Should not be able to refund twice
        vm.expectRevert(ReferralGateway.ReferralGateway__HasNotPaid.selector);
        referralGateway.refundIfDAOIsNotLaunched(child);
        vm.stopPrank();

        (contributionBeforeFee, contributionAfterFee, feeToOperator, discount) = referralGateway
            .getPrepaidMember(child);

        assertEq(contributionBeforeFee, 0);
        assertEq(contributionAfterFee, 0);
        assertEq(feeToOperator, 0);
        assertEq(discount, 0);
        assert(!referralGateway.isMemberKYCed(child));

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__NotKYCed.selector);
        referralGateway.joinDAO(child);
    }

    function testRefundContractDontHaveEnoughBalance()
        public
        setCouponRedeemer
        createDao
        referralPrepays
        KYCReferral
        referredPrepays
        referredIsKYC
    {
        // From parent 20 USDC
        // From child 20 USDC
        // Reward 1
        // Balance 39
        assertEq(usdc.balanceOf(address(referralGateway)), 39e6);

        (
            ,
            ,
            ,
            ,
            uint256 launchDate,
            ,
            uint256 currentAmount,
            ,
            ,
            uint256 toRepool,
            uint256 referralReserve
        ) = referralGateway.getDAOData();

        assertEq(currentAmount, 365e5);
        assertEq(toRepool, 1e6);
        assertEq(referralReserve, 15e5);

        vm.warp(launchDate + 1);
        vm.roll(block.number + 1);

        uint256 referralBalanceBeforeRefund = usdc.balanceOf(referral);

        vm.prank(referral);
        referralGateway.refundIfDAOIsNotLaunched(referral);

        uint256 referralBalanceAfterRefund = usdc.balanceOf(referral);

        // Should refund 25 usdc - discount = 25 - (25 * 10%) = 22.5

        assertEq(referralBalanceAfterRefund, referralBalanceBeforeRefund + 225e5);

        uint256 newExpectedContractBalance = 39e6 - 225e5; // 16.5

        assertEq(usdc.balanceOf(address(referralGateway)), newExpectedContractBalance);

        (, , , , , , currentAmount, , , toRepool, referralReserve) = referralGateway.getDAOData();

        assertEq(currentAmount, 1825e4); // The new currentAmount should be 36.5 - (25 - 25 * 27%) = 36.5 - (25 - 6.75) = 36.5 - 18.25 = 18.25
        assertEq(referralReserve, 0); // The new rr should be 1.5 - (22.5 - 18.25) = 1.5 - 4.25 = 0
        assertEq(toRepool, 0); // The new repool should be 1 - 2.75 = 0

        uint256 amountToRefundToChild = CONTRIBUTION_AMOUNT -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REFERRAL_DISCOUNT_RATIO) / 100); // 25 - (25 * 10%) - (25 * 5%) = 21.25

        vm.prank(child);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReferralGateway.ReferralGateway__NotEnoughFunds.selector,
                amountToRefundToChild,
                newExpectedContractBalance
            )
        );
        referralGateway.refundIfDAOIsNotLaunched(child);

        address usdcWhale = makeAddr("usdcWhale");
        deal(address(usdc), usdcWhale, 100e6);

        vm.prank(usdcWhale);
        usdc.transfer(address(referralGateway), amountToRefundToChild - newExpectedContractBalance);

        assertEq(usdc.balanceOf(address(referralGateway)), amountToRefundToChild);

        uint256 childBalanceBeforeRefund = usdc.balanceOf(child);

        vm.prank(child);
        referralGateway.refundIfDAOIsNotLaunched(child);

        assertEq(usdc.balanceOf(address(child)), childBalanceBeforeRefund + amountToRefundToChild);
        assertEq(usdc.balanceOf(address(referralGateway)), 0);

        (, , , , , , currentAmount, , , toRepool, referralReserve) = referralGateway.getDAOData();

        assertEq(currentAmount, 0);
        assertEq(toRepool, 0);
        assertEq(referralReserve, 0);
    }

    function testCanNotRefundIfDaoIsLaunched()
        public
        setCouponRedeemer
        createDao
        referralPrepays
        KYCReferral
        referredPrepays
        referredIsKYC
    {
        (, , , , uint256 launchDate, , , , , , ) = referralGateway.getDAOData();

        vm.warp(launchDate);
        vm.roll(block.number + 1);

        vm.prank(daoAdmin);
        referralGateway.launchDAO(address(takasureReserve), true);

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.refundIfDAOIsNotLaunched(child);
    }

    function testRefundByAdminEvenIfDaoIsNotYetLaunched()
        public
        setCouponRedeemer
        createDao
        referralPrepays
        KYCReferral
        referredPrepays
        referredIsKYC
    {
        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.refundIfDAOIsNotLaunched(child);

        vm.prank(daoAdmin);
        referralGateway.refundByAdmin(child);
    }
}
