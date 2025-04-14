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

        // Assign implementations
        referralGateway = ReferralGateway(referralGatewayAddress);
        takasureReserve = TakasureReserve(takasureReserveAddress);
        entryModule = EntryModule(entryModuleAddress);
        usdc = IUSDC(usdcAddress);

        // Config mocks
        vm.startPrank(daoAdmin);
        takasureReserve.setNewContributionToken(address(usdc));
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));
        vm.stopPrank();

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

        // Join the dao
        // vm.prank(member);
        // entryModule.joinPool(msg.sender, CONTRIBUTION_AMOUNT, 5);
        // // We simulate a request before the KYC
        // _successResponse(address(bmConsumerMock));
        // vm.prank(daoAdmin);
        // entryModule.approveKYC(member);
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
        referralGateway.createDAO(
            tDaoName,
            true,
            true,
            (block.timestamp + 31_536_000),
            100e6,
            address(bmConsumerMock)
        );

        vm.prank(takadao);
        referralGateway.createDAO(
            tDaoName,
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

        ) = referralGateway.getDAOData(tDaoName);

        assertEq(prejoinEnabled, true);
        assertEq(DAOAdmin, daoAdmin);
        assertEq(DAOAddress, address(0));
        assertEq(launchDate, block.timestamp + 31_536_000);
        assertEq(objectiveAmount, 100e6);
        assertEq(currentAmount, 0);

        vm.prank(takadao);
        vm.expectRevert(ReferralGateway.ReferralGateway__AlreadyExists.selector);
        referralGateway.createDAO(
            tDaoName,
            true,
            true,
            (block.timestamp + 31_536_000),
            100e6,
            address(bmConsumerMock)
        );

        vm.prank(takadao);
        vm.expectRevert(ReferralGateway.ReferralGateway__MustHaveName.selector);
        referralGateway.createDAO(
            "",
            true,
            true,
            (block.timestamp + 31_536_000),
            100e6,
            address(bmConsumerMock)
        );

        vm.prank(takadao);
        vm.expectRevert(ReferralGateway.ReferralGateway__InvalidLaunchDate.selector);
        referralGateway.createDAO("New DAO", true, true, 0, 100e6, address(bmConsumerMock));

        vm.prank(referral);
        vm.expectRevert();
        referralGateway.updateLaunchDate(tDaoName, block.timestamp + 32_000_000);

        vm.prank(daoAdmin);
        referralGateway.updateLaunchDate(tDaoName, block.timestamp + 32_000_000);
    }

    modifier createDao() {
        vm.prank(daoAdmin);
        referralGateway.createDAO(tDaoName, true, true, 1743479999, 1e12, address(bmConsumerMock));
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
        vm.expectRevert();
        referralGateway.launchDAO(tDaoName, address(takasureReserve), true);

        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.launchDAO(tDaoName, address(0), true);

        vm.prank(daoAdmin);
        referralGateway.launchDAO(tDaoName, address(takasureReserve), true);

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

        assertEq(DAOAddress, address(takasureReserve));
        assert(!prejoinEnabled);
        assert(referralDiscount);
        assertEq(rePoolAddress, address(0));

        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__DAOAlreadyLaunched.selector);
        referralGateway.updateLaunchDate(tDaoName, block.timestamp + 32_000_000);

        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__DAOAlreadyLaunched.selector);
        referralGateway.launchDAO(tDaoName, address(takasureReserve), true);

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

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            (((CONTRIBUTION_AMOUNT * REFERRAL_RESERVE) / 100)) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = (CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100;

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

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__ParentMustKYCFirst.selector);
        referralGateway.payContribution(CONTRIBUTION_AMOUNT, tDaoName, referral);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData(tDaoName);

        assertEq(totalCollectedFees, 0);
    }

    //======== preJoinEnabled = true, referralDiscount = false, no referral ========//
    function testprepaymentCase3() public createDao {
        vm.prank(daoAdmin);
        referralGateway.switchReferralDiscount(tDaoName);

        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData(tDaoName);

        assertEq(alreadyCollectedFees, 0);

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = (CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100;

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

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__ParentMustKYCFirst.selector);
        referralGateway.payContribution(CONTRIBUTION_AMOUNT, tDaoName, referral);

        (, , , , , , , uint256 totalCollectedFees, , , ) = referralGateway.getDAOData(tDaoName);

        assertEq(totalCollectedFees, 0);
    }

    modifier referralPrepays() {
        vm.prank(referral);
        referralGateway.payContribution(CONTRIBUTION_AMOUNT, tDaoName, address(0));
        _;
    }

    function testKYCAnAddress() public createDao referralPrepays {
        vm.prank(KYCProvider);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.approveKYC(address(0), tDaoName);

        assert(!referralGateway.isMemberKYCed(referral));
        vm.prank(KYCProvider);
        referralGateway.approveKYC(referral, tDaoName);
        assert(referralGateway.isMemberKYCed(referral));
    }

    function testMustRevertIfKYCTwiceSameAddress() public createDao referralPrepays {
        vm.startPrank(KYCProvider);
        referralGateway.approveKYC(referral, tDaoName);
        vm.expectRevert(ReferralGateway.ReferralGateway__MemberAlreadyKYCed.selector);
        referralGateway.approveKYC(referral, tDaoName);
        vm.stopPrank();
    }

    modifier KYCReferral() {
        vm.prank(KYCProvider);
        referralGateway.approveKYC(referral, tDaoName);
        _;
    }

    //======== preJoinEnabled = true, referralDiscount = true, valid referral ========//
    function testprepaymentCase5() public createDao referralPrepays KYCReferral {
        // Already collected fees with the modifiers logic
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = referralGateway.getDAOData(tDaoName);

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

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100);

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
        referralGateway.approveKYC(child, tDaoName);
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
        referralGateway.launchDAO(tDaoName, address(takasureReserve), true);

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__NotKYCed.selector);
        emit OnMemberJoined(2, child);
        referralGateway.joinDAO(child, tDaoName);
    }

    // function testJoinPool()
    //     public
    //     createDao
    //     referralPrepays
    //     KYCReferral
    //     referredPrepays
    //     referredIsKYC
    // {
    //     (, , , , , , , , , , uint256 referralReserve) = referralGateway.getDAOData(tDaoName);
    //     // Current Referral balance must be
    //     // For referral prepayment: Contribution * 5% = 25 * 5% = 1.25
    //     // For referred prepayment: 2*(Contribution * 5%) - (Contribution * 4%) =>
    //     // 2*(25 * 5%) - (25 * 4%) = 2.5 - 1 = 1.5 => 1_500_000
    //     assertEq(referralReserve, 1_500_000);

    //     uint256 referralGatewayInitialBalance = usdc.balanceOf(address(referralGateway));
    //     uint256 takasureReserveInitialBalance = usdc.balanceOf(address(takasureReserve));
    //     (, uint256 referredContributionAfterFee, , ) = referralGateway.getPrepaidMember(
    //         child,
    //         tDaoName
    //     );
    //     uint256 expectedContributionAfterFee = CONTRIBUTION_AMOUNT -
    //         ((CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100);

    //     assertEq(referredContributionAfterFee, expectedContributionAfterFee);

    //     (, , , , uint256 launchDate, , , , , , ) = referralGateway.getDAOData(tDaoName);

    //     vm.warp(launchDate + 1);
    //     vm.roll(block.number + 1);

    //     vm.prank(daoAdmin);
    //     referralGateway.launchDAO(tDaoName, address(takasureReserve), true);

    //     vm.prank(child);
    //     // vm.expectEmit(true, true, false, false, address(takasureReserve));
    //     // emit OnMemberJoined(2, child);
    //     referralGateway.joinDAO(child, tDaoName);

    //     uint256 referralGatewayFinalBalance = usdc.balanceOf(address(referralGateway));
    //     uint256 takasureReserveFinalBalance = usdc.balanceOf(address(takasureReserve));

    //     assertEq(
    //         referralGatewayFinalBalance,
    //         referralGatewayInitialBalance - referredContributionAfterFee
    //     );
    //     assertEq(
    //         takasureReserveFinalBalance,
    //         takasureReserveInitialBalance + referredContributionAfterFee
    //     );
    // }

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
        referralGateway.approveKYC(parentTier1, tDaoName);

        // Parent 2 prepay referred by parent 1
        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier2);
        referralGateway.payContribution(parentTier2Contribution, tDaoName, parentTier1);

        // The expected parent 1 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentOneReward = (parentTier2Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        vm.prank(takadao);
        vm.expectEmit(true, true, true, true, address(referralGateway));
        emit OnParentRewarded(parentTier1, 1, parentTier2, expectedParentOneReward);
        referralGateway.approveKYC(parentTier2, tDaoName);

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
        referralGateway.approveKYC(parentTier3, tDaoName);

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
        referralGateway.approveKYC(parentTier4, tDaoName);

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
        referralGateway.approveKYC(childWithoutReferee, tDaoName);
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
        referralGateway.approveKYC(parentTier1, tDaoName);

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
        referralGateway.approveKYC(parentTier2, tDaoName);

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
        referralGateway.approveKYC(parentTier3, tDaoName);

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
        referralGateway.approveKYC(parentTier4, tDaoName);

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
        referralGateway.approveKYC(parentTier1, tDaoName);

        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier2);
        referralGateway.payContribution(parentTier2Contribution, tDaoName, parentTier1);

        vm.prank(takadao);
        referralGateway.approveKYC(parentTier2, tDaoName);

        uint256 parentTier3Contribution = 2 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier3);
        referralGateway.payContribution(parentTier3Contribution, tDaoName, parentTier2);

        vm.prank(takadao);
        referralGateway.approveKYC(parentTier3, tDaoName);

        uint256 parentTier4Contribution = 7 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier4);
        referralGateway.payContribution(parentTier4Contribution, tDaoName, parentTier3);

        vm.prank(takadao);
        referralGateway.approveKYC(parentTier4, tDaoName);

        uint256 childWithoutRefereeContribution = 4 * CONTRIBUTION_AMOUNT;
        vm.prank(childWithoutReferee);
        referralGateway.payContribution(childWithoutRefereeContribution, tDaoName, parentTier4);

        vm.prank(takadao);
        referralGateway.approveKYC(childWithoutReferee, tDaoName);

        vm.prank(daoAdmin);
        referralGateway.launchDAO(tDaoName, address(takasureReserve), true);

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
        ) = referralGateway.getDAOData(tDaoName);

        assertEq(currentAmount, 365e5);
        assertEq(toRepool, 1e6);
        assertEq(referralReserve, 15e5);

        vm.warp(launchDate + 1);
        vm.roll(block.number + 1);

        uint256 referralBalanceBeforeRefund = usdc.balanceOf(referral);

        vm.prank(referral);
        referralGateway.refundIfDAOIsNotLaunched(referral, tDaoName);

        uint256 referralBalanceAfterRefund = usdc.balanceOf(referral);

        // Should refund 25 usdc - discount = 25 - (25 * 10%) = 22.5

        assertEq(referralBalanceAfterRefund, referralBalanceBeforeRefund + 225e5);

        uint256 newExpectedContractBalance = 39e6 - 225e5; // 16.5

        assertEq(usdc.balanceOf(address(referralGateway)), newExpectedContractBalance);

        (, , , , , , currentAmount, , , toRepool, referralReserve) = referralGateway.getDAOData(
            tDaoName
        );

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
        referralGateway.refundIfDAOIsNotLaunched(child, tDaoName);

        address usdcWhale = makeAddr("usdcWhale");
        deal(address(usdc), usdcWhale, 100e6);

        vm.prank(usdcWhale);
        usdc.transfer(address(referralGateway), amountToRefundToChild - newExpectedContractBalance);

        assertEq(usdc.balanceOf(address(referralGateway)), amountToRefundToChild);

        uint256 childBalanceBeforeRefund = usdc.balanceOf(child);

        vm.prank(child);
        referralGateway.refundIfDAOIsNotLaunched(child, tDaoName);

        assertEq(usdc.balanceOf(address(child)), childBalanceBeforeRefund + amountToRefundToChild);
        assertEq(usdc.balanceOf(address(referralGateway)), 0);

        (, , , , , , currentAmount, , , toRepool, referralReserve) = referralGateway.getDAOData(
            tDaoName
        );

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
        (, , , , uint256 launchDate, , , , , , ) = referralGateway.getDAOData(tDaoName);

        vm.warp(launchDate);
        vm.roll(block.number + 1);

        vm.prank(daoAdmin);
        referralGateway.launchDAO(tDaoName, address(takasureReserve), true);

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.refundIfDAOIsNotLaunched(child, tDaoName);
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
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.refundIfDAOIsNotLaunched(child, tDaoName);

        vm.prank(daoAdmin);
        referralGateway.refundByAdmin(child, tDaoName);
    }

    /*//////////////////////////////////////////////////////////////
                                     ROLES
        //////////////////////////////////////////////////////////////*/

    function testRoles() public createDao referralPrepays KYCReferral referredPrepays {
        // Addresses that will be used to test the roles
        address newOperator = makeAddr("newOperator");
        address newKYCProvider = makeAddr("newKYCProvider");
        // Current addresses with roles
        assert(referralGateway.hasRole(keccak256("OPERATOR"), takadao));
        assert(referralGateway.hasRole(keccak256("KYC_PROVIDER"), KYCProvider));
        // New addresses without roles
        assert(!referralGateway.hasRole(keccak256("OPERATOR"), newOperator));
        assert(!referralGateway.hasRole(keccak256("KYC_PROVIDER"), newKYCProvider));
        // Current KYCProvider can KYC a member
        vm.prank(KYCProvider);
        referralGateway.approveKYC(child, tDaoName);
        // Grant, revoke and renounce roles
        vm.startPrank(takadao);
        referralGateway.grantRole(keccak256("OPERATOR"), newOperator);
        referralGateway.grantRole(keccak256("KYC_PROVIDER"), newKYCProvider);
        referralGateway.revokeRole(keccak256("OPERATOR"), takadao);
        referralGateway.revokeRole(keccak256("KYC_PROVIDER"), KYCProvider);
        vm.stopPrank();
        // New addresses with roles
        assert(referralGateway.hasRole(keccak256("OPERATOR"), newOperator));
        assert(referralGateway.hasRole(keccak256("KYC_PROVIDER"), newKYCProvider));
        // Old addresses without roles
        assert(!referralGateway.hasRole(keccak256("OPERATOR"), takadao));
        assert(!referralGateway.hasRole(keccak256("KYC_PROVIDER"), KYCProvider));
    }

    function testAdminRole() public createDao referralPrepays KYCReferral referredPrepays {
        // Address that will be used to test the roles
        address newAdmin = makeAddr("newAdmin");
        address newCouponRedeemer = makeAddr("newCouponRedeemer");

        bytes32 defaultAdminRole = 0x00;
        bytes32 couponRedeemer = keccak256("COUPON_REDEEMER");

        // Current address with roles
        assert(referralGateway.hasRole(defaultAdminRole, takadao));

        // New addresses without roles
        assert(!referralGateway.hasRole(defaultAdminRole, newAdmin));

        // Current Admin can give and remove anyone a role
        vm.prank(takadao);
        referralGateway.grantRole(couponRedeemer, newCouponRedeemer);

        assert(referralGateway.hasRole(couponRedeemer, newCouponRedeemer));

        vm.prank(takadao);
        referralGateway.revokeRole(couponRedeemer, newCouponRedeemer);

        assert(!referralGateway.hasRole(couponRedeemer, newCouponRedeemer));

        // Grant, revoke and renounce roles
        vm.startPrank(takadao);
        referralGateway.grantRole(defaultAdminRole, newAdmin);
        referralGateway.renounceRole(defaultAdminRole, takadao);
        vm.stopPrank();

        // New addresses with roles
        assert(referralGateway.hasRole(defaultAdminRole, newAdmin));

        // Old addresses without roles
        assert(!referralGateway.hasRole(defaultAdminRole, takadao));

        // New Admin can give and remove anyone a role
        vm.prank(newAdmin);
        referralGateway.grantRole(couponRedeemer, newCouponRedeemer);

        assert(referralGateway.hasRole(couponRedeemer, newCouponRedeemer));

        vm.prank(newAdmin);
        referralGateway.revokeRole(couponRedeemer, newCouponRedeemer);

        assert(!referralGateway.hasRole(couponRedeemer, newCouponRedeemer));

        // Old Admin can no longer give anyone a role
        vm.prank(takadao);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                takadao,
                defaultAdminRole
            )
        );
        referralGateway.grantRole(couponRedeemer, newCouponRedeemer);
    }
}
