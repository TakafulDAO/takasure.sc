// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract ReferralGatewayTest is Test, SimulateDonResponse {
    TestDeployTakasure deployer;
    ReferralGateway referralGateway;
    TakasurePool takasurePool;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address proxy;
    address daoProxy;
    address takadao;
    address daoAdmin;
    address KYCProvider;
    address referral = makeAddr("referral");
    address member = makeAddr("member");
    address notMember = makeAddr("notMember");
    address child = makeAddr("child");
    string tDaoName = "TheLifeDao";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant LAYER_ONE_REWARD_RATIO = 4; // Layer one reward ratio 4%
    uint256 public constant LAYER_TWO_REWARD_RATIO = 1; // Layer two reward ratio 1%
    uint256 public constant LAYER_THREE_REWARD_RATIO = 35; // Layer three reward ratio 0.35%
    uint256 public constant LAYER_FOUR_REWARD_RATIO = 175; // Layer four reward ratio 0.175%

    bytes32 private constant REFERRAL = keccak256("REFERRAL");

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
    event OnParentRewarded(
        address indexed parent,
        uint256 indexed layer,
        address indexed child,
        uint256 reward
    );
    event OnBenefitMultiplierConsumerChanged(
        address indexed newBenefitMultiplierConsumer,
        address indexed oldBenefitMultiplierConsumer
    );

    function setUp() public {
        // Deployer
        deployer = new TestDeployTakasure();
        // Deploy contracts
        (, bmConsumerMock, daoProxy, proxy, usdcAddress, KYCProvider, helperConfig) = deployer
            .run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        daoAdmin = config.daoMultisig;

        // Assign implementations
        referralGateway = ReferralGateway(address(proxy));
        takasurePool = TakasurePool(address(daoProxy));
        usdc = IUSDC(usdcAddress);

        // Config mocks
        vm.startPrank(daoAdmin);
        takasurePool.setNewContributionToken(address(usdc));
        takasurePool.setNewBenefitMultiplierConsumer(address(bmConsumerMock));

        takasurePool.setNewReferralGateway(address(referralGateway));
        vm.stopPrank();
        vm.prank(msg.sender);
        bmConsumerMock.setNewRequester(address(takasurePool));

        // Give and approve USDC
        deal(address(usdc), referral, USDC_INITIAL_AMOUNT);
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);
        deal(address(usdc), member, USDC_INITIAL_AMOUNT);
        vm.prank(referral);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);
        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);
        vm.prank(member);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);

        // Join the dao
        vm.prank(daoAdmin);
        takasurePool.setKYCStatus(member);
        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));
        vm.prank(member);
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, 5);
    }

    function testSetNewContributionToken() public {
        assertEq(address(referralGateway.usdc()), usdcAddress);

        address newUSDC = makeAddr("newUSDC");

        vm.prank(daoAdmin);
        referralGateway.setUsdcAddress(newUSDC);

        assertEq(address(referralGateway.usdc()), newUSDC);
    }

    /*//////////////////////////////////////////////////////////////
                               CREATE DAO
    //////////////////////////////////////////////////////////////*/
    function testCreateANewDao() public {
        vm.prank(referral);
        vm.expectRevert();
        referralGateway.createDAO(tDaoName, true, true, (block.timestamp + 31_536_000), 100e6);

        vm.prank(takadao);
        referralGateway.createDAO(tDaoName, true, true, (block.timestamp + 31_536_000), 100e6);

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

        ) = referralGateway.getDAOData(tDaoName);

        assertEq(prejoinEnabled, true);
        assertEq(DAOAdmin, daoAdmin);
        assertEq(DAOAddress, address(0));
        assertEq(launchDate, block.timestamp + 31_536_000);
        assertEq(objectiveAmount, 100e6);
        assertEq(currentAmount, 0);

        vm.prank(takadao);
        vm.expectRevert(ReferralGateway.ReferralGateway__AlreadyExists.selector);
        referralGateway.createDAO(tDaoName, true, true, (block.timestamp + 31_536_000), 100e6);

        vm.prank(takadao);
        vm.expectRevert(ReferralGateway.ReferralGateway__MustHaveName.selector);
        referralGateway.createDAO("", true, true, (block.timestamp + 31_536_000), 100e6);

        vm.prank(takadao);
        vm.expectRevert(ReferralGateway.ReferralGateway__InvalidLaunchDate.selector);
        referralGateway.createDAO("New DAO", true, true, 0, 100e6);

        vm.prank(referral);
        vm.expectRevert();
        referralGateway.updateLaunchDate(tDaoName, block.timestamp + 32_000_000);

        vm.prank(daoAdmin);
        referralGateway.updateLaunchDate(tDaoName, block.timestamp + 32_000_000);
    }

    modifier createDao() {
        vm.prank(daoAdmin);
        referralGateway.createDAO(tDaoName, true, true, 1743479999, 1e12);
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

        ) = referralGateway.getDAOData(tDaoName);

        assertEq(DAOAddress, address(0));
        assertEq(prejoinEnabled, true);
        assertEq(referralDiscount, true);

        vm.prank(referral);
        vm.expectRevert(ReferralGateway.ReferralGateway__onlyDAOAdmin.selector);
        referralGateway.launchDAO(tDaoName, address(takasurePool), true);

        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.launchDAO(tDaoName, address(0), true);

        vm.prank(daoAdmin);
        referralGateway.launchDAO(tDaoName, address(takasurePool), true);

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

        ) = referralGateway.getDAOData(tDaoName);

        assertEq(DAOAddress, address(takasurePool));
        assert(!prejoinEnabled);
        assert(referralDiscount);
        assertEq(rePoolAddress, address(0));

        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__DAOAlreadyLaunched.selector);
        referralGateway.updateLaunchDate(tDaoName, block.timestamp + 32_000_000);

        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__DAOAlreadyLaunched.selector);
        referralGateway.launchDAO(tDaoName, address(takasurePool), true);

        vm.prank(daoAdmin);
        referralGateway.switchReferralDiscount(tDaoName);

        (, referralDiscount, , , , , , , , , ) = referralGateway.getDAOData(tDaoName);

        assert(!referralDiscount);

        address newRePoolAddress = makeAddr("rePoolAddress");

        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.enableRepool(tDaoName, address(0));

        vm.prank(daoAdmin);
        referralGateway.enableRepool(tDaoName, newRePoolAddress);

        (, , , , , , , , rePoolAddress, , ) = referralGateway.getDAOData(tDaoName);

        assertEq(rePoolAddress, newRePoolAddress);
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    function testMustRevertIfprepaymentContributionIsOutOfRange() public createDao {
        // 24.99 USDC
        vm.startPrank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__ContributionOutOfRange.selector);
        referralGateway.payContribution(2499e4, tDaoName, referral);

        // 250.01 USDC
        vm.expectRevert(ReferralGateway.ReferralGateway__ContributionOutOfRange.selector);
        referralGateway.payContribution(25001e4, tDaoName, referral);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                    PREPAYS
        //////////////////////////////////////////////////////////////*/

    //======== preJoinEnabled = true, referralDiscount = true, no referral ========//
    function testprepaymentCase1() public createDao {
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData(tDaoName);

        assertEq(alreadyCollectedFees, 0);

        uint256 fees = (CONTRIBUTION_AMOUNT * referralGateway.SERVICE_FEE_RATIO()) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * referralGateway.CONTRIBUTION_PREJOIN_DISCOUNT_RATIO()) / 100) -
            (((CONTRIBUTION_AMOUNT * referralGateway.REFERRAL_RESERVE()) / 100)) -
            ((CONTRIBUTION_AMOUNT * referralGateway.REPOOL_FEE_RATIO()) / 100);

        uint256 expectedDiscount = (CONTRIBUTION_AMOUNT *
            referralGateway.CONTRIBUTION_PREJOIN_DISCOUNT_RATIO()) / 100;

        vm.prank(child);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(address(0), child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContribution(CONTRIBUTION_AMOUNT, tDaoName, address(0));

        (, , , uint256 discount) = referralGateway.getPrepaidMember(child, tDaoName);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData(tDaoName);

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 2_500_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = true, referralDiscount = true, invalid referral ========//
    function testprepaymentCase2() public createDao {
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData(tDaoName);

        assertEq(alreadyCollectedFees, 0);

        uint256 expectedParentReward = 0; // Because the parent is not a member yet

        uint256 fees = (CONTRIBUTION_AMOUNT * referralGateway.SERVICE_FEE_RATIO()) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * referralGateway.CONTRIBUTION_PREJOIN_DISCOUNT_RATIO()) / 100) -
            ((CONTRIBUTION_AMOUNT * referralGateway.REFERRAL_RESERVE()) / 100) -
            ((CONTRIBUTION_AMOUNT * referralGateway.REPOOL_FEE_RATIO()) / 100);

        uint256 expectedDiscount = (CONTRIBUTION_AMOUNT *
            referralGateway.CONTRIBUTION_PREJOIN_DISCOUNT_RATIO()) / 100;

        vm.prank(child);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(referral, child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContribution(CONTRIBUTION_AMOUNT, tDaoName, referral);

        (, , , uint256 discount) = referralGateway.getPrepaidMember(child, tDaoName);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData(tDaoName);

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 2_500_000);
        assertEq(
            referralGateway.getParentRewardsByChild(referral, child, tDaoName),
            expectedParentReward
        );
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = true, referralDiscount = false, no referral ========//
    function testprepaymentCase3() public createDao {
        vm.prank(daoAdmin);
        referralGateway.switchReferralDiscount(tDaoName);

        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData(tDaoName);

        assertEq(alreadyCollectedFees, 0);

        uint256 fees = (CONTRIBUTION_AMOUNT * referralGateway.SERVICE_FEE_RATIO()) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * referralGateway.CONTRIBUTION_PREJOIN_DISCOUNT_RATIO()) / 100) -
            ((CONTRIBUTION_AMOUNT * referralGateway.REPOOL_FEE_RATIO()) / 100);

        uint256 expectedDiscount = (CONTRIBUTION_AMOUNT *
            referralGateway.CONTRIBUTION_PREJOIN_DISCOUNT_RATIO()) / 100;

        vm.prank(child);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(address(0), child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContribution(CONTRIBUTION_AMOUNT, tDaoName, address(0));

        (, , , uint256 discount) = referralGateway.getPrepaidMember(child, tDaoName);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData(tDaoName);

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 3_750_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = true, referralDiscount = false, invalid referral ========//
    function testprepaymentCase4() public createDao {
        vm.prank(daoAdmin);
        referralGateway.switchReferralDiscount(tDaoName);

        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData(tDaoName);

        assertEq(alreadyCollectedFees, 0);

        uint256 expectedParentReward = 0; // Because the parent is not a member yet

        uint256 fees = (CONTRIBUTION_AMOUNT * referralGateway.SERVICE_FEE_RATIO()) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * referralGateway.CONTRIBUTION_PREJOIN_DISCOUNT_RATIO()) / 100) -
            ((CONTRIBUTION_AMOUNT * referralGateway.REPOOL_FEE_RATIO()) / 100);

        uint256 expectedDiscount = (CONTRIBUTION_AMOUNT *
            referralGateway.CONTRIBUTION_PREJOIN_DISCOUNT_RATIO()) / 100;

        vm.prank(child);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(referral, child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContribution(CONTRIBUTION_AMOUNT, tDaoName, referral);

        (, , , uint256 discount) = referralGateway.getPrepaidMember(child, tDaoName);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData(tDaoName);

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 3_750_000);
        assertEq(
            referralGateway.getParentRewardsByChild(referral, child, tDaoName),
            expectedParentReward
        );
        assertEq(discount, expectedDiscount);
    }

    modifier referralPrepays() {
        vm.prank(referral);
        referralGateway.payContribution(CONTRIBUTION_AMOUNT, tDaoName, address(0));
        _;
    }

    function testKYCAnAddress() public createDao referralPrepays {
        vm.prank(KYCProvider);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.setKYCStatus(address(0), tDaoName);

        assert(!referralGateway.isMemberKYCed(referral));
        vm.prank(KYCProvider);
        referralGateway.setKYCStatus(referral, tDaoName);
        assert(referralGateway.isMemberKYCed(referral));
    }

    function testMustRevertIfKYCTwiceSameAddress() public createDao referralPrepays {
        vm.startPrank(KYCProvider);
        referralGateway.setKYCStatus(referral, tDaoName);
        vm.expectRevert(ReferralGateway.ReferralGateway__MemberAlreadyKYCed.selector);
        referralGateway.setKYCStatus(referral, tDaoName);
        vm.stopPrank();
    }

    modifier KYCReferral() {
        vm.prank(KYCProvider);
        referralGateway.setKYCStatus(referral, tDaoName);
        _;
    }

    //======== preJoinEnabled = true, referralDiscount = true, valid referral ========//
    function testprepaymentCase5() public createDao referralPrepays KYCReferral {
        // Already collected fees with the modifiers logic
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData(tDaoName);

        assertEq(alreadyCollectedFees, 2_500_000);

        uint256 expectedParentReward = (CONTRIBUTION_AMOUNT * LAYER_ONE_REWARD_RATIO) / 100;

        uint256 fees = (CONTRIBUTION_AMOUNT * referralGateway.SERVICE_FEE_RATIO()) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * referralGateway.CONTRIBUTION_PREJOIN_DISCOUNT_RATIO()) / 100) -
            ((CONTRIBUTION_AMOUNT * referralGateway.REFERRAL_RESERVE()) / 100) -
            ((CONTRIBUTION_AMOUNT * referralGateway.REFERRAL_DISCOUNT_RATIO()) / 100) -
            ((CONTRIBUTION_AMOUNT * referralGateway.REPOOL_FEE_RATIO()) / 100);

        uint256 expectedDiscount = ((CONTRIBUTION_AMOUNT *
            referralGateway.CONTRIBUTION_PREJOIN_DISCOUNT_RATIO()) / 100) +
            ((CONTRIBUTION_AMOUNT * referralGateway.REFERRAL_DISCOUNT_RATIO()) / 100);

        vm.prank(child);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(referral, child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContribution(CONTRIBUTION_AMOUNT, tDaoName, referral);

        (, , , uint256 discount) = referralGateway.getPrepaidMember(child, tDaoName);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData(tDaoName);

        assertEq(collectedFees, 1_250_000);
        assertEq(totalCollectedFees, collectedFees + alreadyCollectedFees);
        assertEq(
            referralGateway.getParentRewardsByChild(referral, child, tDaoName),
            expectedParentReward
        );
        assertEq(expectedParentReward, 1_000_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = true, referralDiscount = false, valid referral ========//
    function testprepaymentCase6() public createDao referralPrepays KYCReferral {
        vm.prank(daoAdmin);
        referralGateway.switchReferralDiscount(tDaoName);

        // Already collected fees with the modifiers logic
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData(tDaoName);
        assertEq(alreadyCollectedFees, 2_500_000);

        uint256 expectedParentReward = 0;

        uint256 fees = (CONTRIBUTION_AMOUNT * referralGateway.SERVICE_FEE_RATIO()) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * referralGateway.CONTRIBUTION_PREJOIN_DISCOUNT_RATIO()) / 100) -
            ((CONTRIBUTION_AMOUNT * referralGateway.REPOOL_FEE_RATIO()) / 100);

        uint256 expectedDiscount = ((CONTRIBUTION_AMOUNT *
            referralGateway.CONTRIBUTION_PREJOIN_DISCOUNT_RATIO()) / 100);

        vm.prank(child);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnPrepayment(referral, child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        referralGateway.payContribution(CONTRIBUTION_AMOUNT, tDaoName, referral);

        (, , , uint256 discount) = referralGateway.getPrepaidMember(child, tDaoName);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData(tDaoName);

        assertEq(collectedFees, 3_750_000);
        assertEq(totalCollectedFees, collectedFees + alreadyCollectedFees);
        assertEq(
            referralGateway.getParentRewardsByChild(referral, child, tDaoName),
            expectedParentReward
        );
        assertEq(discount, expectedDiscount);
    }

    modifier referredPrepays() {
        vm.prank(child);
        referralGateway.payContribution(CONTRIBUTION_AMOUNT, tDaoName, referral);

        _;
    }

    modifier referredIsKYC() {
        vm.prank(KYCProvider);
        referralGateway.setKYCStatus(child, tDaoName);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                      JOIN
        //////////////////////////////////////////////////////////////*/

    function testMustRevertJoinPoolIfTheDaoHasNoAssignedAddressYet()
        public
        createDao
        referralPrepays
        KYCReferral
    {
        vm.prank(referral);
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        emit OnMemberJoined(2, referral);
        referralGateway.joinDAO(referral, tDaoName);
    }

    function testMustRevertJoinPoolIfTheChildIsNotKYC()
        public
        createDao
        referralPrepays
        KYCReferral
        referredPrepays
    {
        vm.prank(daoAdmin);
        referralGateway.launchDAO(tDaoName, address(takasurePool), true);

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__NotKYCed.selector);
        emit OnMemberJoined(2, child);
        referralGateway.joinDAO(child, tDaoName);
    }

    function testJoinPool()
        public
        createDao
        referralPrepays
        KYCReferral
        referredPrepays
        referredIsKYC
    {
        (, , , , , , , , , , uint256 referralReserve) = referralGateway.getDAOData(tDaoName);
        // Current Referral balance must be
        // For referral prepayment: Contribution * 5% = 25 * 5% = 1.25
        // For referred prepayment: 2*(Contribution * 5%) - (Contribution * 4%) =>
        // 2*(25 * 5%) - (25 * 4%) = 2.5 - 1 = 1.5 => 1_500_000
        assertEq(referralReserve, 1_500_000);

        uint256 referralGatewayInitialBalance = usdc.balanceOf(address(referralGateway));
        uint256 takasurePoolInitialBalance = usdc.balanceOf(address(takasurePool));
        (, uint256 referredContributionAfterFee, , ) = referralGateway.getPrepaidMember(
            child,
            tDaoName
        );
        uint256 expectedContributionAfterFee = CONTRIBUTION_AMOUNT -
            ((CONTRIBUTION_AMOUNT * referralGateway.SERVICE_FEE_RATIO()) / 100);

        assertEq(referredContributionAfterFee, expectedContributionAfterFee);

        (, , , , uint256 launchDate, , , , , , ) = referralGateway.getDAOData(tDaoName);

        vm.warp(launchDate + 1);
        vm.roll(block.number + 1);

        vm.prank(daoAdmin);
        referralGateway.launchDAO(tDaoName, address(takasurePool), true);

        vm.prank(child);
        vm.expectEmit(true, true, false, false, address(takasurePool));
        emit OnMemberJoined(2, child);
        referralGateway.joinDAO(child, tDaoName);

        uint256 referralGatewayFinalBalance = usdc.balanceOf(address(referralGateway));
        uint256 takasurePoolFinalBalance = usdc.balanceOf(address(takasurePool));

        assertEq(
            referralGatewayFinalBalance,
            referralGatewayInitialBalance - referredContributionAfterFee
        );
        assertEq(
            takasurePoolFinalBalance,
            takasurePoolInitialBalance + referredContributionAfterFee
        );
    }

    /*//////////////////////////////////////////////////////////////
                                  GRANDPARENTS
        //////////////////////////////////////////////////////////////*/

    function testCompleteReferralTreeAssignRewardCorrectly() public createDao {
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
        vm.prank(parentTier1);
        referralGateway.payContribution(CONTRIBUTION_AMOUNT, tDaoName, address(0));
        vm.prank(takadao);
        referralGateway.setKYCStatus(parentTier1, tDaoName);

        // Parent 2 prepay referred by parent 1
        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier2);
        referralGateway.payContribution(parentTier2Contribution, tDaoName, parentTier1);

        // The expected parent 1 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentOneReward = (parentTier2Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        vm.prank(takadao);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewarded(parentTier1, 1, parentTier2, expectedParentOneReward);
        referralGateway.setKYCStatus(parentTier2, tDaoName);

        // Parent 3 prepay referred by parent 2
        uint256 parentTier3Contribution = 2 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier3);
        referralGateway.payContribution(parentTier3Contribution, tDaoName, parentTier2);

        // The expected parent 2 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentTwoReward = (parentTier3Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 1% of the parent 2 contribution
        expectedParentOneReward = (parentTier3Contribution * LAYER_TWO_REWARD_RATIO) / 100;

        vm.prank(takadao);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewarded(parentTier2, 1, parentTier3, expectedParentTwoReward);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewarded(parentTier1, 2, parentTier3, expectedParentOneReward);
        referralGateway.setKYCStatus(parentTier3, tDaoName);

        // Parent 4 prepay referred by parent 3
        uint256 parentTier4Contribution = 7 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier4);
        referralGateway.payContribution(parentTier4Contribution, tDaoName, parentTier3);

        // The expected parent 3 reward ratio will be 4% of the parent 4 contribution
        uint256 expectedParentThreeReward = (parentTier4Contribution * LAYER_ONE_REWARD_RATIO) /
            100;
        // The expected parent 2 reward ratio will be 1% of the parent 4 contribution
        expectedParentTwoReward = (parentTier4Contribution * LAYER_TWO_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 0.35% of the parent 4 contribution
        expectedParentOneReward = (parentTier4Contribution * LAYER_THREE_REWARD_RATIO) / 10000;

        vm.prank(takadao);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewarded(parentTier3, 1, parentTier4, expectedParentThreeReward);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewarded(parentTier2, 2, parentTier4, expectedParentTwoReward);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewarded(parentTier1, 3, parentTier4, expectedParentOneReward);
        referralGateway.setKYCStatus(parentTier4, tDaoName);

        // Child without referee prepay referred by parent 4
        uint256 childWithoutRefereeContribution = 4 * CONTRIBUTION_AMOUNT;
        vm.prank(childWithoutReferee);
        referralGateway.payContribution(childWithoutRefereeContribution, tDaoName, parentTier4);

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

        vm.prank(takadao);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewarded(parentTier4, 1, childWithoutReferee, expectedParentFourReward);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewarded(parentTier3, 2, childWithoutReferee, expectedParentThreeReward);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewarded(parentTier2, 3, childWithoutReferee, expectedParentTwoReward);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewarded(parentTier1, 4, childWithoutReferee, expectedParentOneReward);
        referralGateway.setKYCStatus(childWithoutReferee, tDaoName);
    }

    function testLayersCorrectlyAssigned() public createDao {
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
        vm.prank(parentTier1);
        referralGateway.payContribution(CONTRIBUTION_AMOUNT, tDaoName, address(0));
        vm.prank(takadao);
        referralGateway.setKYCStatus(parentTier1, tDaoName);

        // Now parent 1 refer parent 2, this refer parent 3, this refer parent 4 and this refer the child

        // Parent 2 prepay referred by parent 1
        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;

        vm.prank(parentTier2);
        referralGateway.payContribution(parentTier2Contribution, tDaoName, parentTier1);

        // The expected parent 1 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentOneReward = (parentTier2Contribution * LAYER_ONE_REWARD_RATIO) / 100;

        assertEq(
            referralGateway.getParentRewardsByChild(parentTier1, parentTier2, tDaoName),
            expectedParentOneReward
        );
        assertEq(
            referralGateway.getParentRewardsByLayer(parentTier1, 1, tDaoName),
            expectedParentOneReward
        );

        // Parent 3 prepay referred by parent 2
        vm.prank(takadao);
        referralGateway.setKYCStatus(parentTier2, tDaoName);

        uint256 parentTier3Contribution = 2 * CONTRIBUTION_AMOUNT;
        // The expected parent 2 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentTwoReward = (parentTier3Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 1% of the parent 2 contribution
        expectedParentOneReward = (parentTier3Contribution * LAYER_TWO_REWARD_RATIO) / 100;

        vm.prank(parentTier3);
        referralGateway.payContribution(parentTier3Contribution, tDaoName, parentTier2);

        assertEq(
            referralGateway.getParentRewardsByChild(parentTier2, parentTier3, tDaoName),
            expectedParentTwoReward
        );
        assertEq(
            referralGateway.getParentRewardsByLayer(parentTier2, 1, tDaoName),
            expectedParentTwoReward
        );
        assertEq(
            referralGateway.getParentRewardsByLayer(parentTier1, 2, tDaoName),
            expectedParentOneReward
        );

        // Parent 4 prepay referred by parent 3
        vm.prank(takadao);
        referralGateway.setKYCStatus(parentTier3, tDaoName);

        uint256 parentTier4Contribution = 7 * CONTRIBUTION_AMOUNT;
        // The expected parent 3 reward ratio will be 4% of the parent 4 contribution
        uint256 expectedParentThreeReward = (parentTier4Contribution * LAYER_ONE_REWARD_RATIO) /
            100;
        // The expected parent 2 reward ratio will be 1% of the parent 4 contribution
        expectedParentTwoReward = (parentTier4Contribution * LAYER_TWO_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 0.35% of the parent 4 contribution
        expectedParentOneReward = (parentTier4Contribution * LAYER_THREE_REWARD_RATIO) / 10000;

        vm.prank(parentTier4);
        referralGateway.payContribution(parentTier4Contribution, tDaoName, parentTier3);

        assertEq(
            referralGateway.getParentRewardsByChild(parentTier3, parentTier4, tDaoName),
            expectedParentThreeReward
        );
        assertEq(
            referralGateway.getParentRewardsByLayer(parentTier3, 1, tDaoName),
            expectedParentThreeReward
        );
        assertEq(
            referralGateway.getParentRewardsByLayer(parentTier2, 2, tDaoName),
            expectedParentTwoReward
        );
        assertEq(
            referralGateway.getParentRewardsByLayer(parentTier1, 3, tDaoName),
            expectedParentOneReward
        );

        // Child without referee prepay referred by parent 4
        vm.prank(takadao);
        referralGateway.setKYCStatus(parentTier4, tDaoName);

        // The expected parent 4 reward ratio will be 4% of the child without referee contribution
        uint256 expectedParentFourReward = (CONTRIBUTION_AMOUNT * LAYER_ONE_REWARD_RATIO) / 100;
        // The expected parent 3 reward ratio will be 1% of the child without referee
        expectedParentThreeReward = (CONTRIBUTION_AMOUNT * LAYER_TWO_REWARD_RATIO) / 100;
        // The expected parent 2 reward ratio will be 0.35% of the child without referee contribution
        expectedParentTwoReward = (CONTRIBUTION_AMOUNT * LAYER_THREE_REWARD_RATIO) / 10000;
        // The expected parent 1 reward ratio will be 0.175% of the child without referee contribution
        expectedParentOneReward = (CONTRIBUTION_AMOUNT * LAYER_FOUR_REWARD_RATIO) / 100000;

        vm.prank(childWithoutReferee);
        referralGateway.payContribution(CONTRIBUTION_AMOUNT, tDaoName, parentTier4);

        assertEq(
            referralGateway.getParentRewardsByChild(parentTier4, childWithoutReferee, tDaoName),
            expectedParentFourReward
        );
        assertEq(
            referralGateway.getParentRewardsByLayer(parentTier4, 1, tDaoName),
            expectedParentFourReward
        );
        assertEq(
            referralGateway.getParentRewardsByLayer(parentTier3, 2, tDaoName),
            expectedParentThreeReward
        );
        assertEq(
            referralGateway.getParentRewardsByLayer(parentTier2, 3, tDaoName),
            expectedParentTwoReward
        );
        assertEq(
            referralGateway.getParentRewardsByLayer(parentTier1, 4, tDaoName),
            expectedParentOneReward
        );
    }

    /*//////////////////////////////////////////////////////////////
                                     REPOOL
        //////////////////////////////////////////////////////////////*/

    function testTransferToRepool() public createDao {
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

        vm.prank(parentTier1);
        referralGateway.payContribution(CONTRIBUTION_AMOUNT, tDaoName, address(0));
        vm.prank(takadao);
        referralGateway.setKYCStatus(parentTier1, tDaoName);

        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier2);
        referralGateway.payContribution(parentTier2Contribution, tDaoName, parentTier1);

        vm.prank(takadao);
        referralGateway.setKYCStatus(parentTier2, tDaoName);

        uint256 parentTier3Contribution = 2 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier3);
        referralGateway.payContribution(parentTier3Contribution, tDaoName, parentTier2);

        vm.prank(takadao);
        referralGateway.setKYCStatus(parentTier3, tDaoName);

        uint256 parentTier4Contribution = 7 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier4);
        referralGateway.payContribution(parentTier4Contribution, tDaoName, parentTier3);

        vm.prank(takadao);
        referralGateway.setKYCStatus(parentTier4, tDaoName);

        uint256 childWithoutRefereeContribution = 4 * CONTRIBUTION_AMOUNT;
        vm.prank(childWithoutReferee);
        referralGateway.payContribution(childWithoutRefereeContribution, tDaoName, parentTier4);

        vm.prank(takadao);
        referralGateway.setKYCStatus(childWithoutReferee, tDaoName);

        vm.prank(daoAdmin);
        referralGateway.launchDAO(tDaoName, address(takasurePool), true);

        address rePoolAddress = makeAddr("rePoolAddress");

        vm.prank(daoAdmin);
        referralGateway.enableRepool(tDaoName, rePoolAddress);

        (, , , , , , , , , uint256 toRepool, ) = referralGateway.getDAOData(tDaoName);

        assert(toRepool > 0);
        assertEq(usdc.balanceOf(rePoolAddress), 0);

        vm.prank(daoAdmin);
        referralGateway.transferToRepool(tDaoName);

        (, , , , , , , , , uint256 newRepoolBalance, ) = referralGateway.getDAOData(tDaoName);

        assertEq(newRepoolBalance, 0);
        assertEq(usdc.balanceOf(rePoolAddress), toRepool);
    }

    /*//////////////////////////////////////////////////////////////
                                    REFUNDS
        //////////////////////////////////////////////////////////////*/

    function testRefund()
        public
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
        ) = referralGateway.getPrepaidMember(child, tDaoName);

        assert(contributionBeforeFee > 0);
        assert(contributionAfterFee > 0);
        assert(feeToOperator > 0);
        assert(discount > 0);
        assert(referralGateway.isMemberKYCed(child));

        vm.startPrank(child);
        // Should not be able to join because the DAO is not launched yet
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.joinDAO(child, tDaoName);

        // Should not be able to refund because the launched date is not reached yet
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.refundIfDAOIsNotLaunched(child, tDaoName);
        vm.stopPrank();

        (, , , , uint256 launchDate, , , , , , ) = referralGateway.getDAOData(tDaoName);

        vm.warp(launchDate);
        vm.roll(block.number + 1);

        vm.startPrank(child);
        // Should not be able to join because the DAO is not launched yet
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.joinDAO(child, tDaoName);

        // Should not be able to refund even if the launched date is reached, but has to wait 1 day
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.refundIfDAOIsNotLaunched(child, tDaoName);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        vm.startPrank(child);
        referralGateway.refundIfDAOIsNotLaunched(child, tDaoName);

        // Should not be able to refund twice
        vm.expectRevert(ReferralGateway.ReferralGateway__HasNotPaid.selector);
        referralGateway.refundIfDAOIsNotLaunched(child, tDaoName);
        vm.stopPrank();

        (contributionBeforeFee, contributionAfterFee, feeToOperator, discount) = referralGateway
            .getPrepaidMember(child, tDaoName);

        assertEq(contributionBeforeFee, 0);
        assertEq(contributionAfterFee, 0);
        assertEq(feeToOperator, 0);
        assertEq(discount, 0);
        assert(!referralGateway.isMemberKYCed(child));

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__NotKYCed.selector);
        referralGateway.joinDAO(child, tDaoName);
    }

    function testCanNotRefundIfDaoIsLaunched()
        public
        createDao
        referralPrepays
        KYCReferral
        referredPrepays
        referredIsKYC
    {
        (, , , , uint256 launchDate, , , , , , ) = referralGateway.getDAOData(tDaoName);

        vm.warp(launchDate);
        vm.roll(block.number + 1);

        vm.prank(daoAdmin);
        referralGateway.launchDAO(tDaoName, address(takasurePool), true);

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.refundIfDAOIsNotLaunched(child, tDaoName);
    }

    /*//////////////////////////////////////////////////////////////
                                     ROLES
        //////////////////////////////////////////////////////////////*/

    function testRoles() public createDao referralPrepays referredPrepays {
        // Addresses that will be used to test the roles
        address newOperator = makeAddr("newOperator");
        address newKYCProvider = makeAddr("newKYCProvider");
        address newAdmin = makeAddr("newAdmin");
        address newCofounderOfChange = makeAddr("newCofounderOfChange");

        // Current addresses with roles
        assert(referralGateway.hasRole(keccak256("OPERATOR"), takadao));
        assert(referralGateway.hasRole(keccak256("KYC_PROVIDER"), KYCProvider));
        assert(referralGateway.hasRole(0x00, takadao));

        // New addresses without roles
        assert(!referralGateway.hasRole(keccak256("OPERATOR"), newOperator));
        assert(!referralGateway.hasRole(keccak256("KYC_PROVIDER"), newKYCProvider));
        assert(!referralGateway.hasRole(0x00, newAdmin));
        assert(!referralGateway.hasRole(keccak256("COFOUNDER_OF_CHANGE"), newCofounderOfChange));

        vm.prank(takadao);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.registerCofounderOfChange(address(0));

        vm.prank(takadao);
        referralGateway.registerCofounderOfChange(newCofounderOfChange);

        assert(referralGateway.hasRole(keccak256("COFOUNDER_OF_CHANGE"), newCofounderOfChange));

        // Current KYCProvider can KYC a member
        vm.prank(KYCProvider);
        referralGateway.setKYCStatus(referral, tDaoName);

        // Grant, revoke and renounce roles
        vm.startPrank(takadao);
        referralGateway.grantRole(keccak256("OPERATOR"), newOperator);
        referralGateway.grantRole(keccak256("KYC_PROVIDER"), newKYCProvider);
        referralGateway.grantRole(0x00, newAdmin);
        referralGateway.revokeRole(keccak256("OPERATOR"), takadao);
        referralGateway.revokeRole(keccak256("KYC_PROVIDER"), KYCProvider);
        referralGateway.renounceRole(0x00, takadao);
        vm.stopPrank();

        // Previous KYCProvider can not KYC a member
        vm.prank(KYCProvider);
        vm.expectRevert();
        referralGateway.setKYCStatus(child, tDaoName);

        // New KYCProvider can KYC a member
        vm.prank(newKYCProvider);
        referralGateway.setKYCStatus(child, tDaoName);

        // New addresses with roles
        assert(referralGateway.hasRole(keccak256("OPERATOR"), newOperator));
        assert(referralGateway.hasRole(keccak256("KYC_PROVIDER"), newKYCProvider));
        assert(referralGateway.hasRole(0x00, newAdmin));

        // Old addresses without roles
        assert(!referralGateway.hasRole(keccak256("OPERATOR"), takadao));
        assert(!referralGateway.hasRole(keccak256("KYC_PROVIDER"), KYCProvider));
        assert(!referralGateway.hasRole(0x00, takadao));
    }

    /*//////////////////////////////////////////////////////////////
                                    CONSUMER
        //////////////////////////////////////////////////////////////*/
    function testChangeBMConsumer() public {
        vm.prank(takadao);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.setNewBenefitMultiplierConsumer(address(0));

        uint256 bmConsumerAddressSlot = 1;
        bytes32 operatorAddressSlotBytes = vm.load(
            address(referralGateway),
            bytes32(uint256(bmConsumerAddressSlot))
        );
        address bmConsumer = address(uint160(uint256(operatorAddressSlotBytes)));

        assertEq(bmConsumer, address(bmConsumerMock));

        address newBMConsumer = makeAddr("newBMConsumer");

        vm.prank(referral);
        vm.expectRevert();
        referralGateway.setNewBenefitMultiplierConsumer(newBMConsumer);

        vm.prank(takadao);
        vm.expectEmit(true, true, false, false, address(referralGateway));
        emit OnBenefitMultiplierConsumerChanged(newBMConsumer, address(bmConsumerMock));
        referralGateway.setNewBenefitMultiplierConsumer(newBMConsumer);

        operatorAddressSlotBytes = vm.load(
            address(referralGateway),
            bytes32(uint256(bmConsumerAddressSlot))
        );
        bmConsumer = address(uint160(uint256(operatorAddressSlotBytes)));

        assertEq(bmConsumer, address(newBMConsumer));
    }
}
