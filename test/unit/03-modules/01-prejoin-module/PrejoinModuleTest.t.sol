// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {PrejoinModule} from "contracts/modules/PrejoinModule.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";
import {AddressCheck} from "contracts/helpers/libraries/checks/AddressCheck.sol";

contract PrejoinModuleTest is Test, SimulateDonResponse {
    TestDeployProtocol deployer;
    PrejoinModule prejoinModule;
    TakasureReserve takasureReserve;
    EntryModule entryModule;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address prejoinModuleAddress;
    address takasureReserveAddress;
    address entryModuleAddress;
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
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (
            ,
            bmConsumerMock,
            takasureReserveAddress,
            prejoinModuleAddress,
            entryModuleAddress,
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
        daoAdmin = config.daoMultisig;
        KYCProvider = config.kycProvider;

        // Assign implementations
        prejoinModule = PrejoinModule(prejoinModuleAddress);
        takasureReserve = TakasureReserve(takasureReserveAddress);
        entryModule = EntryModule(entryModuleAddress);
        usdc = IUSDC(usdcAddress);

        // Config mocks
        vm.startPrank(daoAdmin);
        takasureReserve.setNewContributionToken(address(usdc));
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));
        takasureReserve.setNewReferralGateway(address(prejoinModule));
        vm.stopPrank();

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(takasureReserve));
        bmConsumerMock.setNewRequester(prejoinModuleAddress);

        // Give and approve USDC
        deal(address(usdc), referral, USDC_INITIAL_AMOUNT);
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);
        deal(address(usdc), member, USDC_INITIAL_AMOUNT);

        vm.prank(referral);
        usdc.approve(address(prejoinModule), USDC_INITIAL_AMOUNT);
        vm.prank(child);
        usdc.approve(address(prejoinModule), USDC_INITIAL_AMOUNT);
        vm.prank(member);
        usdc.approve(address(takasureReserve), USDC_INITIAL_AMOUNT);

        // Join the dao
        // vm.prank(member);
        // entryModule.joinPool(msg.sender, CONTRIBUTION_AMOUNT, 5);
        // // We simulate a request before the KYC
        // _successResponse(address(bmConsumerMock));
        // vm.prank(daoAdmin);
        // entryModule.setKYCStatus(member);
    }

    function testSetNewContributionToken() public {
        assertEq(address(prejoinModule.usdc()), usdcAddress);

        address newUSDC = makeAddr("newUSDC");

        vm.prank(daoAdmin);
        prejoinModule.setUsdcAddress(newUSDC);

        assertEq(address(prejoinModule.usdc()), newUSDC);
    }

    /*//////////////////////////////////////////////////////////////
                               CREATE DAO
    //////////////////////////////////////////////////////////////*/
    function testCreateANewDao() public {
        vm.prank(referral);
        vm.expectRevert();
        prejoinModule.createDAO(
            tDaoName,
            true,
            true,
            (block.timestamp + 31_536_000),
            100e6,
            address(bmConsumerMock)
        );

        vm.startPrank(takadao);
        prejoinModule.createDAO(
            tDaoName,
            true,
            true,
            (block.timestamp + 31_536_000),
            100e6,
            address(bmConsumerMock)
        );
        prejoinModule.setDAOName(tDaoName);
        vm.stopPrank();

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

        ) = prejoinModule.getDAOData();

        assertEq(prejoinEnabled, true);
        assertEq(DAOAdmin, daoAdmin);
        assertEq(DAOAddress, address(0));
        assertEq(launchDate, block.timestamp + 31_536_000);
        assertEq(objectiveAmount, 100e6);
        assertEq(currentAmount, 0);

        vm.prank(referral);
        vm.expectRevert();
        prejoinModule.updateLaunchDate(block.timestamp + 32_000_000);

        vm.prank(daoAdmin);
        prejoinModule.updateLaunchDate(block.timestamp + 32_000_000);
    }

    modifier createDao() {
        vm.startPrank(daoAdmin);
        prejoinModule.createDAO(tDaoName, true, true, 1743479999, 1e12, address(bmConsumerMock));
        prejoinModule.setDAOName(tDaoName);
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

        ) = prejoinModule.getDAOData();

        assertEq(DAOAddress, address(0));
        assertEq(prejoinEnabled, true);
        assertEq(referralDiscount, true);

        vm.prank(referral);
        vm.expectRevert(PrejoinModule.PrejoinModule__onlyDAOAdmin.selector);
        prejoinModule.launchDAO(address(takasureReserve), true);

        vm.prank(daoAdmin);
        vm.expectRevert(AddressCheck.TakasureProtocol__ZeroAddress.selector);
        prejoinModule.launchDAO(address(0), true);

        vm.prank(daoAdmin);
        prejoinModule.launchDAO(address(takasureReserve), true);

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

        ) = prejoinModule.getDAOData();

        assertEq(DAOAddress, address(takasureReserve));
        assert(!prejoinEnabled);
        assert(referralDiscount);
        assertEq(rePoolAddress, address(0));

        vm.prank(daoAdmin);
        vm.expectRevert(PrejoinModule.PrejoinModule__DAOAlreadyLaunched.selector);
        prejoinModule.updateLaunchDate(block.timestamp + 32_000_000);

        vm.prank(daoAdmin);
        vm.expectRevert(PrejoinModule.PrejoinModule__DAOAlreadyLaunched.selector);
        prejoinModule.launchDAO(address(takasureReserve), true);

        vm.prank(daoAdmin);
        prejoinModule.switchReferralDiscount();

        (, referralDiscount, , , , , , , , , ) = prejoinModule.getDAOData();

        assert(!referralDiscount);

        address newRePoolAddress = makeAddr("rePoolAddress");

        vm.prank(daoAdmin);
        vm.expectRevert(AddressCheck.TakasureProtocol__ZeroAddress.selector);
        prejoinModule.enableRepool(address(0));

        vm.prank(daoAdmin);
        prejoinModule.enableRepool(newRePoolAddress);

        (, , , , , , , , rePoolAddress, , ) = prejoinModule.getDAOData();

        assertEq(rePoolAddress, newRePoolAddress);
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    function testMustRevertIfprepaymentContributionIsOutOfRange() public createDao {
        // 24.99 USDC
        vm.startPrank(child);
        vm.expectRevert(PrejoinModule.PrejoinModule__ContributionOutOfRange.selector);
        prejoinModule.payContribution(2499e4, referral);

        // 250.01 USDC
        vm.expectRevert(PrejoinModule.PrejoinModule__ContributionOutOfRange.selector);
        prejoinModule.payContribution(25001e4, referral);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                    PREPAYS
        //////////////////////////////////////////////////////////////*/

    //======== preJoinEnabled = true, referralDiscount = true, no referral ========//
    function testprepaymentCase1() public createDao {
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(alreadyCollectedFees, 0);

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            (((CONTRIBUTION_AMOUNT * REFERRAL_RESERVE) / 100)) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = (CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100;

        vm.prank(child);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnPrepayment(address(0), child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, address(0));

        (, , , uint256 discount) = prejoinModule.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 2_500_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = true, referralDiscount = true, invalid referral ========//
    function testprepaymentCase2() public createDao {
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(alreadyCollectedFees, 0);

        vm.prank(child);
        vm.expectRevert(PrejoinModule.PrejoinModule__ParentMustKYCFirst.selector);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, referral);

        (, , , , , , , uint256 totalCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(totalCollectedFees, 0);
    }

    //======== preJoinEnabled = true, referralDiscount = false, no referral ========//
    function testprepaymentCase3() public createDao {
        vm.prank(daoAdmin);
        prejoinModule.switchReferralDiscount();

        (, , , , , , , uint256 alreadyCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(alreadyCollectedFees, 0);

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = (CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100;

        vm.prank(child);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnPrepayment(address(0), child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, address(0));

        (, , , uint256 discount) = prejoinModule.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 3_750_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = true, referralDiscount = false, invalid referral ========//
    function testprepaymentCase4() public createDao {
        vm.prank(daoAdmin);
        prejoinModule.switchReferralDiscount();

        (, , , , , , , uint256 alreadyCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(alreadyCollectedFees, 0);

        vm.prank(child);
        vm.expectRevert(PrejoinModule.PrejoinModule__ParentMustKYCFirst.selector);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, referral);

        (, , , , , , , uint256 totalCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(totalCollectedFees, 0);
    }

    modifier referralPrepays() {
        vm.prank(referral);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, address(0));
        _;
    }

    function testKYCAnAddress() public createDao referralPrepays {
        vm.prank(KYCProvider);
        vm.expectRevert(AddressCheck.TakasureProtocol__ZeroAddress.selector);
        prejoinModule.setKYCStatus(address(0));

        assert(!prejoinModule.isMemberKYCed(referral));
        vm.prank(KYCProvider);
        prejoinModule.setKYCStatus(referral);
        assert(prejoinModule.isMemberKYCed(referral));
    }

    function testMustRevertIfKYCTwiceSameAddress() public createDao referralPrepays {
        vm.startPrank(KYCProvider);
        prejoinModule.setKYCStatus(referral);
        vm.expectRevert(PrejoinModule.PrejoinModule__MemberAlreadyKYCed.selector);
        prejoinModule.setKYCStatus(referral);
        vm.stopPrank();
    }

    modifier KYCReferral() {
        vm.prank(KYCProvider);
        prejoinModule.setKYCStatus(referral);
        _;
    }

    //======== preJoinEnabled = true, referralDiscount = true, valid referral ========//
    function testprepaymentCase5() public createDao referralPrepays KYCReferral {
        // Already collected fees with the modifiers logic
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = prejoinModule.getDAOData();

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

        vm.prank(child);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnPrepayment(referral, child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, referral);

        (, , , uint256 discount) = prejoinModule.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(collectedFees, 1_250_000);
        assertEq(totalCollectedFees, collectedFees + alreadyCollectedFees);
        assertEq(prejoinModule.getParentRewardsByChild(referral, child), expectedParentReward);
        assertEq(expectedParentReward, 1_000_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = true, referralDiscount = false, valid referral ========//
    function testprepaymentCase6() public createDao referralPrepays KYCReferral {
        vm.prank(daoAdmin);
        prejoinModule.switchReferralDiscount();

        // Already collected fees with the modifiers logic
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = prejoinModule.getDAOData();
        assertEq(alreadyCollectedFees, 2_500_000);

        uint256 expectedParentReward = 0;

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100);

        vm.prank(child);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnPrepayment(referral, child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, referral);

        (, , , uint256 discount) = prejoinModule.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(collectedFees, 3_750_000);
        assertEq(totalCollectedFees, collectedFees + alreadyCollectedFees);
        assertEq(prejoinModule.getParentRewardsByChild(referral, child), expectedParentReward);
        assertEq(discount, expectedDiscount);
    }

    modifier referredPrepays() {
        vm.prank(child);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, referral);

        _;
    }

    modifier referredIsKYC() {
        vm.prank(KYCProvider);
        prejoinModule.setKYCStatus(child);
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
        vm.expectRevert(PrejoinModule.PrejoinModule__tDAONotReadyYet.selector);
        emit OnMemberJoined(2, referral);
        prejoinModule.joinDAO(referral);
    }

    function testMustRevertJoinPoolIfTheChildIsNotKYC()
        public
        createDao
        referralPrepays
        KYCReferral
        referredPrepays
    {
        vm.prank(daoAdmin);
        prejoinModule.launchDAO(address(takasureReserve), true);

        vm.prank(child);
        vm.expectRevert(PrejoinModule.PrejoinModule__NotKYCed.selector);
        emit OnMemberJoined(2, child);
        prejoinModule.joinDAO(child);
    }

    function testJoinPool()
        public
        createDao
        referralPrepays
        KYCReferral
        referredPrepays
        referredIsKYC
    {
        (, , , , , , , , , , uint256 referralReserve) = prejoinModule.getDAOData();
        // Current Referral balance must be
        // For referral prepayment: Contribution * 5% = 25 * 5% = 1.25
        // For referred prepayment: 2*(Contribution * 5%) - (Contribution * 4%) =>
        // 2*(25 * 5%) - (25 * 4%) = 2.5 - 1 = 1.5 => 1_500_000
        assertEq(referralReserve, 1_500_000);

        uint256 prejoinModuleInitialBalance = usdc.balanceOf(address(prejoinModule));
        uint256 takasureReserveInitialBalance = usdc.balanceOf(address(takasureReserve));
        (, uint256 referredContributionAfterFee, , ) = prejoinModule.getPrepaidMember(child);
        uint256 expectedContributionAfterFee = CONTRIBUTION_AMOUNT -
            ((CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100);

        assertEq(referredContributionAfterFee, expectedContributionAfterFee);

        (, , , , uint256 launchDate, , , , , , ) = prejoinModule.getDAOData();

        vm.warp(launchDate + 1);
        vm.roll(block.number + 1);

        vm.prank(daoAdmin);
        prejoinModule.launchDAO(address(takasureReserve), true);

        vm.prank(child);
        // vm.expectEmit(true, true, false, false, address(takasureReserve));
        // emit OnMemberJoined(2, child);
        prejoinModule.joinDAO(child);

        uint256 prejoinModuleFinalBalance = usdc.balanceOf(address(prejoinModule));
        uint256 takasureReserveFinalBalance = usdc.balanceOf(address(takasureReserve));

        assertEq(
            prejoinModuleFinalBalance,
            prejoinModuleInitialBalance - referredContributionAfterFee
        );
        assertEq(
            takasureReserveFinalBalance,
            takasureReserveInitialBalance + referredContributionAfterFee
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
            usdc.approve(address(prejoinModule), 10 * CONTRIBUTION_AMOUNT);
            vm.stopPrank();
        }

        address childWithoutReferee = makeAddr("childWithoutReferee");
        deal(address(usdc), childWithoutReferee, 10 * CONTRIBUTION_AMOUNT);
        vm.prank(childWithoutReferee);
        usdc.approve(address(prejoinModule), 10 * CONTRIBUTION_AMOUNT);

        // First Parent 1 becomes a member without a referral
        vm.prank(parentTier1);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, address(0));
        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier1);

        // Parent 2 prepay referred by parent 1
        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier2);
        prejoinModule.payContribution(parentTier2Contribution, parentTier1);

        // The expected parent 1 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentOneReward = (parentTier2Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        vm.prank(takadao);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier1, 1, parentTier2, expectedParentOneReward);
        prejoinModule.setKYCStatus(parentTier2);

        // Parent 3 prepay referred by parent 2
        uint256 parentTier3Contribution = 2 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier3);
        prejoinModule.payContribution(parentTier3Contribution, parentTier2);

        // The expected parent 2 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentTwoReward = (parentTier3Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 1% of the parent 2 contribution
        expectedParentOneReward = (parentTier3Contribution * LAYER_TWO_REWARD_RATIO) / 100;

        vm.prank(takadao);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier2, 1, parentTier3, expectedParentTwoReward);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier1, 2, parentTier3, expectedParentOneReward);
        prejoinModule.setKYCStatus(parentTier3);

        // Parent 4 prepay referred by parent 3
        uint256 parentTier4Contribution = 7 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier4);
        prejoinModule.payContribution(parentTier4Contribution, parentTier3);

        // The expected parent 3 reward ratio will be 4% of the parent 4 contribution
        uint256 expectedParentThreeReward = (parentTier4Contribution * LAYER_ONE_REWARD_RATIO) /
            100;
        // The expected parent 2 reward ratio will be 1% of the parent 4 contribution
        expectedParentTwoReward = (parentTier4Contribution * LAYER_TWO_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 0.35% of the parent 4 contribution
        expectedParentOneReward = (parentTier4Contribution * LAYER_THREE_REWARD_RATIO) / 10000;

        vm.prank(takadao);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier3, 1, parentTier4, expectedParentThreeReward);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier2, 2, parentTier4, expectedParentTwoReward);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier1, 3, parentTier4, expectedParentOneReward);
        prejoinModule.setKYCStatus(parentTier4);

        // Child without referee prepay referred by parent 4
        uint256 childWithoutRefereeContribution = 4 * CONTRIBUTION_AMOUNT;
        vm.prank(childWithoutReferee);
        prejoinModule.payContribution(childWithoutRefereeContribution, parentTier4);

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
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier4, 1, childWithoutReferee, expectedParentFourReward);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier3, 2, childWithoutReferee, expectedParentThreeReward);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier2, 3, childWithoutReferee, expectedParentTwoReward);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier1, 4, childWithoutReferee, expectedParentOneReward);
        prejoinModule.setKYCStatus(childWithoutReferee);
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
            usdc.approve(address(prejoinModule), 10 * CONTRIBUTION_AMOUNT);
            vm.stopPrank();
        }
        address childWithoutReferee = makeAddr("childWithoutReferee");

        deal(address(usdc), childWithoutReferee, 10 * CONTRIBUTION_AMOUNT);
        vm.prank(childWithoutReferee);
        usdc.approve(address(prejoinModule), 10 * CONTRIBUTION_AMOUNT);

        // First Parent 1 becomes a member without a referral
        vm.prank(parentTier1);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, address(0));
        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier1);

        // Now parent 1 refer parent 2, this refer parent 3, this refer parent 4 and this refer the child

        // Parent 2 prepay referred by parent 1
        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;

        vm.prank(parentTier2);
        prejoinModule.payContribution(parentTier2Contribution, parentTier1);

        // The expected parent 1 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentOneReward = (parentTier2Contribution * LAYER_ONE_REWARD_RATIO) / 100;

        assertEq(
            prejoinModule.getParentRewardsByChild(parentTier1, parentTier2),
            expectedParentOneReward
        );
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier1, 1), expectedParentOneReward);

        // Parent 3 prepay referred by parent 2
        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier2);

        uint256 parentTier3Contribution = 2 * CONTRIBUTION_AMOUNT;
        // The expected parent 2 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentTwoReward = (parentTier3Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 1% of the parent 2 contribution
        expectedParentOneReward = (parentTier3Contribution * LAYER_TWO_REWARD_RATIO) / 100;

        vm.prank(parentTier3);
        prejoinModule.payContribution(parentTier3Contribution, parentTier2);

        assertEq(
            prejoinModule.getParentRewardsByChild(parentTier2, parentTier3),
            expectedParentTwoReward
        );
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier2, 1), expectedParentTwoReward);
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier1, 2), expectedParentOneReward);

        // Parent 4 prepay referred by parent 3
        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier3);

        uint256 parentTier4Contribution = 7 * CONTRIBUTION_AMOUNT;
        // The expected parent 3 reward ratio will be 4% of the parent 4 contribution
        uint256 expectedParentThreeReward = (parentTier4Contribution * LAYER_ONE_REWARD_RATIO) /
            100;
        // The expected parent 2 reward ratio will be 1% of the parent 4 contribution
        expectedParentTwoReward = (parentTier4Contribution * LAYER_TWO_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 0.35% of the parent 4 contribution
        expectedParentOneReward = (parentTier4Contribution * LAYER_THREE_REWARD_RATIO) / 10000;

        vm.prank(parentTier4);
        prejoinModule.payContribution(parentTier4Contribution, parentTier3);

        assertEq(
            prejoinModule.getParentRewardsByChild(parentTier3, parentTier4),
            expectedParentThreeReward
        );
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier3, 1), expectedParentThreeReward);
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier2, 2), expectedParentTwoReward);
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier1, 3), expectedParentOneReward);

        // Child without referee prepay referred by parent 4
        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier4);

        // The expected parent 4 reward ratio will be 4% of the child without referee contribution
        uint256 expectedParentFourReward = (CONTRIBUTION_AMOUNT * LAYER_ONE_REWARD_RATIO) / 100;
        // The expected parent 3 reward ratio will be 1% of the child without referee
        expectedParentThreeReward = (CONTRIBUTION_AMOUNT * LAYER_TWO_REWARD_RATIO) / 100;
        // The expected parent 2 reward ratio will be 0.35% of the child without referee contribution
        expectedParentTwoReward = (CONTRIBUTION_AMOUNT * LAYER_THREE_REWARD_RATIO) / 10000;
        // The expected parent 1 reward ratio will be 0.175% of the child without referee contribution
        expectedParentOneReward = (CONTRIBUTION_AMOUNT * LAYER_FOUR_REWARD_RATIO) / 100000;

        vm.prank(childWithoutReferee);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, parentTier4);

        assertEq(
            prejoinModule.getParentRewardsByChild(parentTier4, childWithoutReferee),
            expectedParentFourReward
        );
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier4, 1), expectedParentFourReward);
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier3, 2), expectedParentThreeReward);
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier2, 3), expectedParentTwoReward);
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier1, 4), expectedParentOneReward);
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
            usdc.approve(address(prejoinModule), 10 * CONTRIBUTION_AMOUNT);
            vm.stopPrank();
        }

        address childWithoutReferee = makeAddr("childWithoutReferee");
        deal(address(usdc), childWithoutReferee, 10 * CONTRIBUTION_AMOUNT);
        vm.prank(childWithoutReferee);
        usdc.approve(address(prejoinModule), 10 * CONTRIBUTION_AMOUNT);

        vm.prank(parentTier1);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, address(0));
        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier1);

        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier2);
        prejoinModule.payContribution(parentTier2Contribution, parentTier1);

        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier2);

        uint256 parentTier3Contribution = 2 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier3);
        prejoinModule.payContribution(parentTier3Contribution, parentTier2);

        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier3);

        uint256 parentTier4Contribution = 7 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier4);
        prejoinModule.payContribution(parentTier4Contribution, parentTier3);

        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier4);

        uint256 childWithoutRefereeContribution = 4 * CONTRIBUTION_AMOUNT;
        vm.prank(childWithoutReferee);
        prejoinModule.payContribution(childWithoutRefereeContribution, parentTier4);

        vm.prank(takadao);
        prejoinModule.setKYCStatus(childWithoutReferee);

        vm.prank(daoAdmin);
        prejoinModule.launchDAO(address(takasureReserve), true);

        address rePoolAddress = makeAddr("rePoolAddress");

        vm.prank(daoAdmin);
        prejoinModule.enableRepool(rePoolAddress);

        (, , , , , , , , , uint256 toRepool, ) = prejoinModule.getDAOData();

        assert(toRepool > 0);
        assertEq(usdc.balanceOf(rePoolAddress), 0);

        vm.prank(daoAdmin);
        prejoinModule.transferToRepool();

        (, , , , , , , , , uint256 newRepoolBalance, ) = prejoinModule.getDAOData();

        assertEq(newRepoolBalance, 0);
        assertEq(usdc.balanceOf(rePoolAddress), toRepool);
    }

    /*//////////////////////////////////////////////////////////////
                                    REFUNDS
        //////////////////////////////////////////////////////////////*/

    function testRefundContractHasEnoughBalance()
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
        ) = prejoinModule.getPrepaidMember(child);

        assert(contributionBeforeFee > 0);
        assert(contributionAfterFee > 0);
        assert(feeToOperator > 0);
        assert(discount > 0);
        assert(prejoinModule.isMemberKYCed(child));

        vm.startPrank(child);
        // Should not be able to join because the DAO is not launched yet
        vm.expectRevert(PrejoinModule.PrejoinModule__tDAONotReadyYet.selector);
        prejoinModule.joinDAO(child);

        // Should not be able to refund because the launched date is not reached yet
        vm.expectRevert(PrejoinModule.PrejoinModule__tDAONotReadyYet.selector);
        prejoinModule.refundIfDAOIsNotLaunched(child);
        vm.stopPrank();

        (, , , , uint256 launchDate, , , , , , ) = prejoinModule.getDAOData();

        vm.warp(launchDate);
        vm.roll(block.number + 1);

        vm.startPrank(child);
        // Should not be able to join because the DAO is not launched yet
        vm.expectRevert(PrejoinModule.PrejoinModule__tDAONotReadyYet.selector);
        prejoinModule.joinDAO(child);

        // Should not be able to refund even if the launched date is reached, but has to wait 1 day
        vm.expectRevert(PrejoinModule.PrejoinModule__tDAONotReadyYet.selector);
        prejoinModule.refundIfDAOIsNotLaunched(child);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        vm.startPrank(child);
        prejoinModule.refundIfDAOIsNotLaunched(child);

        // Should not be able to refund twice
        vm.expectRevert(PrejoinModule.PrejoinModule__HasNotPaid.selector);
        prejoinModule.refundIfDAOIsNotLaunched(child);
        vm.stopPrank();

        (contributionBeforeFee, contributionAfterFee, feeToOperator, discount) = prejoinModule
            .getPrepaidMember(child);

        assertEq(contributionBeforeFee, 0);
        assertEq(contributionAfterFee, 0);
        assertEq(feeToOperator, 0);
        assertEq(discount, 0);
        assert(!prejoinModule.isMemberKYCed(child));

        vm.prank(child);
        vm.expectRevert(PrejoinModule.PrejoinModule__NotKYCed.selector);
        prejoinModule.joinDAO(child);
    }

    function testRefundContractDontHaveEnoughBalance()
        public
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
        assertEq(usdc.balanceOf(address(prejoinModule)), 39e6);

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
        ) = prejoinModule.getDAOData();

        assertEq(currentAmount, 365e5);
        assertEq(toRepool, 1e6);
        assertEq(referralReserve, 15e5);

        vm.warp(launchDate + 1);
        vm.roll(block.number + 1);

        uint256 referralBalanceBeforeRefund = usdc.balanceOf(referral);

        vm.prank(referral);
        prejoinModule.refundIfDAOIsNotLaunched(referral);

        uint256 referralBalanceAfterRefund = usdc.balanceOf(referral);

        // Should refund 25 usdc - discount = 25 - (25 * 10%) = 22.5

        assertEq(referralBalanceAfterRefund, referralBalanceBeforeRefund + 225e5);

        uint256 newExpectedContractBalance = 39e6 - 225e5; // 16.5

        assertEq(usdc.balanceOf(address(prejoinModule)), newExpectedContractBalance);

        (, , , , , , currentAmount, , , toRepool, referralReserve) = prejoinModule.getDAOData();

        assertEq(currentAmount, 1825e4); // The new currentAmount should be 36.5 - (25 - 25 * 27%) = 36.5 - (25 - 6.75) = 36.5 - 18.25 = 18.25
        assertEq(referralReserve, 0); // The new rr should be 1.5 - (22.5 - 18.25) = 1.5 - 4.25 = 0
        assertEq(toRepool, 0); // The new repool should be 1 - 2.75 = 0

        uint256 amountToRefundToChild = CONTRIBUTION_AMOUNT -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REFERRAL_DISCOUNT_RATIO) / 100); // 25 - (25 * 10%) - (25 * 5%) = 21.25

        vm.prank(child);
        vm.expectRevert(
            abi.encodeWithSelector(
                PrejoinModule.PrejoinModule__NotEnoughFunds.selector,
                amountToRefundToChild,
                newExpectedContractBalance
            )
        );
        prejoinModule.refundIfDAOIsNotLaunched(child);

        address usdcWhale = makeAddr("usdcWhale");
        deal(address(usdc), usdcWhale, 100e6);

        vm.prank(usdcWhale);
        usdc.transfer(address(prejoinModule), amountToRefundToChild - newExpectedContractBalance);

        assertEq(usdc.balanceOf(address(prejoinModule)), amountToRefundToChild);

        uint256 childBalanceBeforeRefund = usdc.balanceOf(child);

        vm.prank(child);
        prejoinModule.refundIfDAOIsNotLaunched(child);

        assertEq(usdc.balanceOf(address(child)), childBalanceBeforeRefund + amountToRefundToChild);
        assertEq(usdc.balanceOf(address(prejoinModule)), 0);

        (, , , , , , currentAmount, , , toRepool, referralReserve) = prejoinModule.getDAOData();

        assertEq(currentAmount, 0);
        assertEq(toRepool, 0);
        assertEq(referralReserve, 0);
    }

    function testCanNotRefundIfDaoIsLaunched()
        public
        createDao
        referralPrepays
        KYCReferral
        referredPrepays
        referredIsKYC
    {
        (, , , , uint256 launchDate, , , , , , ) = prejoinModule.getDAOData();

        vm.warp(launchDate);
        vm.roll(block.number + 1);

        vm.prank(daoAdmin);
        prejoinModule.launchDAO(address(takasureReserve), true);

        vm.prank(child);
        vm.expectRevert(PrejoinModule.PrejoinModule__tDAONotReadyYet.selector);
        prejoinModule.refundIfDAOIsNotLaunched(child);
    }

    function testRefundByAdminEvenIfDaoIsNotYetLaunched()
        public
        createDao
        referralPrepays
        KYCReferral
        referredPrepays
        referredIsKYC
    {
        vm.prank(daoAdmin);
        vm.expectRevert(PrejoinModule.PrejoinModule__tDAONotReadyYet.selector);
        prejoinModule.refundIfDAOIsNotLaunched(child);

        vm.prank(daoAdmin);
        prejoinModule.refundByAdmin(child);
    }

    /*//////////////////////////////////////////////////////////////
                                     ROLES
        //////////////////////////////////////////////////////////////*/

    function testRoles() public createDao referralPrepays KYCReferral referredPrepays {
        // Addresses that will be used to test the roles
        address newOperator = makeAddr("newOperator");
        address newKYCProvider = makeAddr("newKYCProvider");
        // Current addresses with roles
        assert(prejoinModule.hasRole(keccak256("OPERATOR"), takadao));
        assert(prejoinModule.hasRole(keccak256("KYC_PROVIDER"), KYCProvider));
        // New addresses without roles
        assert(!prejoinModule.hasRole(keccak256("OPERATOR"), newOperator));
        assert(!prejoinModule.hasRole(keccak256("KYC_PROVIDER"), newKYCProvider));
        // Current KYCProvider can KYC a member
        vm.prank(KYCProvider);
        prejoinModule.setKYCStatus(child);
        // Grant, revoke and renounce roles
        vm.startPrank(takadao);
        prejoinModule.grantRole(keccak256("OPERATOR"), newOperator);
        prejoinModule.grantRole(keccak256("KYC_PROVIDER"), newKYCProvider);
        prejoinModule.revokeRole(keccak256("OPERATOR"), takadao);
        prejoinModule.revokeRole(keccak256("KYC_PROVIDER"), KYCProvider);
        vm.stopPrank();
        // New addresses with roles
        assert(prejoinModule.hasRole(keccak256("OPERATOR"), newOperator));
        assert(prejoinModule.hasRole(keccak256("KYC_PROVIDER"), newKYCProvider));
        // Old addresses without roles
        assert(!prejoinModule.hasRole(keccak256("OPERATOR"), takadao));
        assert(!prejoinModule.hasRole(keccak256("KYC_PROVIDER"), KYCProvider));
    }

    function testAdminRole() public createDao referralPrepays KYCReferral referredPrepays {
        // Address that will be used to test the roles
        address newAdmin = makeAddr("newAdmin");
        address newCouponRedeemer = makeAddr("newCouponRedeemer");

        bytes32 defaultAdminRole = 0x00;
        bytes32 couponRedeemer = keccak256("COUPON_REDEEMER");

        // Current address with roles
        assert(prejoinModule.hasRole(defaultAdminRole, takadao));

        // New addresses without roles
        assert(!prejoinModule.hasRole(defaultAdminRole, newAdmin));

        // Current Admin can give and remove anyone a role
        vm.prank(takadao);
        prejoinModule.grantRole(couponRedeemer, newCouponRedeemer);

        assert(prejoinModule.hasRole(couponRedeemer, newCouponRedeemer));

        vm.prank(takadao);
        prejoinModule.revokeRole(couponRedeemer, newCouponRedeemer);

        assert(!prejoinModule.hasRole(couponRedeemer, newCouponRedeemer));

        // Grant, revoke and renounce roles
        vm.startPrank(takadao);
        prejoinModule.grantRole(defaultAdminRole, newAdmin);
        prejoinModule.renounceRole(defaultAdminRole, takadao);
        vm.stopPrank();

        // New addresses with roles
        assert(prejoinModule.hasRole(defaultAdminRole, newAdmin));

        // Old addresses without roles
        assert(!prejoinModule.hasRole(defaultAdminRole, takadao));

        // New Admin can give and remove anyone a role
        vm.prank(newAdmin);
        prejoinModule.grantRole(couponRedeemer, newCouponRedeemer);

        assert(prejoinModule.hasRole(couponRedeemer, newCouponRedeemer));

        vm.prank(newAdmin);
        prejoinModule.revokeRole(couponRedeemer, newCouponRedeemer);

        assert(!prejoinModule.hasRole(couponRedeemer, newCouponRedeemer));

        // Old Admin can no longer give anyone a role
        vm.prank(takadao);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                takadao,
                defaultAdminRole
            )
        );
        prejoinModule.grantRole(couponRedeemer, newCouponRedeemer);
    }
}
