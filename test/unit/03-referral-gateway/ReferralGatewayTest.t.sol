// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployReferralGateway} from "test/utils/TestDeployReferralGateway.s.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {DeployConsumerMocks} from "test/utils/DeployConsumerMocks.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract ReferralGatewayTest is Test, SimulateDonResponse {
    TestDeployReferralGateway deployer;
    TestDeployTakasure daoDeployer;
    DeployConsumerMocks mockDeployer;
    ReferralGateway referralGateway;
    TakasurePool takasurePool;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address proxy;
    address daoProxy;
    address takadao;
    address admin;
    address kycProvider;
    address daoAdmin = makeAddr("daoAdmin");
    address ambassador = makeAddr("ambassador");
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

    bytes32 private constant AMBASSADOR = keccak256("AMBASSADOR");

    event OnPreJoinEnabledChanged(bool indexed isPreJoinEnabled);
    event OnNewAmbassadorProposal(address indexed proposedAmbassador);
    event OnNewAmbassador(address indexed ambassador);
    event OnPrePayment(address indexed parent, address indexed child, uint256 indexed contribution);
    event OnMemberJoined(uint256 indexed memberId, address indexed member);
    event OnNewDaoCreated(string indexed daoName);
    event OnParentRewarded(address indexed parent, address indexed child, uint256 indexed reward);

    function setUp() public {
        // Deployers
        deployer = new TestDeployReferralGateway();
        daoDeployer = new TestDeployTakasure();
        mockDeployer = new DeployConsumerMocks();

        // Deploy contracts
        (, proxy, usdcAddress, kycProvider, helperConfig) = deployer.run();
        (, daoProxy, , ) = daoDeployer.run();
        bmConsumerMock = mockDeployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        admin = config.daoMultisig;

        // Assign implementations
        referralGateway = ReferralGateway(address(proxy));
        takasurePool = TakasurePool(address(daoProxy));
        usdc = IUSDC(usdcAddress);

        // Config mocks
        vm.startPrank(admin);
        takasurePool.setNewContributionToken(address(usdc));
        takasurePool.setNewBenefitMultiplierConsumer(address(bmConsumerMock));
        takasurePool.setNewReferralGateway(address(referralGateway));
        vm.stopPrank();
        vm.prank(msg.sender);
        bmConsumerMock.setNewRequester(address(takasurePool));

        // Give and approve USDC
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);
        deal(address(usdc), member, USDC_INITIAL_AMOUNT);
        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);
        vm.prank(member);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);

        // Join the dao
        vm.prank(admin);
        takasurePool.setKYCStatus(member);
        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));
        vm.prank(member);
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, 5);
    }

    /*//////////////////////////////////////////////////////////////
                               CREATE DAO
    //////////////////////////////////////////////////////////////*/
    function testCreateANewDao() public {
        vm.prank(daoAdmin);
        // vm.expectEmit(true, false, false, false, address(takasurePool));
        // emit OnNewDaoCreated(tDaoName);
        referralGateway.createDao(tDaoName, true, 0, 100e6);

        assertEq(referralGateway.getDaoData(tDaoName).name, tDaoName);
        assertEq(referralGateway.getDaoData(tDaoName).isPreJoinEnabled, true);
        assertEq(referralGateway.getDaoData(tDaoName).prePaymentAdmin, daoAdmin);
        assertEq(referralGateway.getDaoData(tDaoName).daoAddress, address(0));
        assertEq(referralGateway.getDaoData(tDaoName).launchDate, 0);
        assertEq(referralGateway.getDaoData(tDaoName).objectiveAmount, 100e6);
        assertEq(referralGateway.getDaoData(tDaoName).currentAmount, 0);
    }

    modifier createDao() {
        vm.prank(daoAdmin);
        referralGateway.createDao(tDaoName, true, 1743479999, 1e12);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/
    function testSetIsPreJoinEnabled() public createDao {
        assert(referralGateway.getDaoData(tDaoName).isPreJoinEnabled);

        vm.prank(daoAdmin);
        vm.expectEmit(true, false, false, false, address(referralGateway));
        emit OnPreJoinEnabledChanged(false);
        referralGateway.setPreJoinEnabled(tDaoName, false);

        assert(!referralGateway.getDaoData(tDaoName).isPreJoinEnabled);
    }

    function testAssignTDAOAddress() public createDao {
        assertEq(referralGateway.getDaoData(tDaoName).daoAddress, address(0));
        vm.prank(daoAdmin);
        referralGateway.assignTDaoAddress(tDaoName, address(takasurePool));
        assertEq(referralGateway.getDaoData(tDaoName).daoAddress, address(takasurePool));
    }

    modifier assignTDAOAddress() {
        vm.prank(daoAdmin);
        referralGateway.assignTDaoAddress(tDaoName, address(takasurePool));
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    function testRegisterAmbassadorMustRevertIfIsAddressZero() public {
        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.registerAmbassador(address(0));
    }

    function testMustRevertIfPrePaymentIsDisabled() public createDao {
        vm.prank(daoAdmin);
        referralGateway.setPreJoinEnabled(tDaoName, false);

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__NotAllowedToPrePay.selector);
        referralGateway.prePayment(ambassador, 25e6, tDaoName);
    }

    function testMustRevertIfPrePaymentContributionIsOutOfRange() public createDao {
        vm.startPrank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__ContributionOutOfRange.selector);
        referralGateway.prePayment(ambassador, 20e6, tDaoName);

        vm.expectRevert(ReferralGateway.ReferralGateway__ContributionOutOfRange.selector);
        referralGateway.prePayment(ambassador, 300e6, tDaoName);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              AMBASSADORS
    //////////////////////////////////////////////////////////////*/

    function testRegisterAmbassador() public {
        assert(!referralGateway.hasRole(AMBASSADOR, ambassador));
        vm.prank(takadao);
        vm.expectEmit(true, false, false, false, address(referralGateway));
        emit OnNewAmbassador(ambassador);
        referralGateway.registerAmbassador(ambassador);

        assert(referralGateway.hasRole(AMBASSADOR, ambassador));
    }

    modifier registerAmbassador() {
        vm.prank(takadao);
        referralGateway.registerAmbassador(ambassador);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                  KYC
    //////////////////////////////////////////////////////////////*/

    function testKycAnAddress() public {
        assert(!referralGateway.isChildKYCed(child));
        vm.prank(kycProvider);
        referralGateway.setKYCStatus(child);
        assert(referralGateway.isChildKYCed(child));
    }

    function testMustRevertIfKycTwiceSameAddress() public {
        vm.startPrank(kycProvider);
        referralGateway.setKYCStatus(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__MemberAlreadyKYCed.selector);
        referralGateway.setKYCStatus(child);
        vm.stopPrank();
    }

    modifier kycChild() {
        vm.prank(kycProvider);
        referralGateway.setKYCStatus(child);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                PREPAYS
    //////////////////////////////////////////////////////////////*/

    function testPrePaymentParentAmbassadorChildrenNotKYCedNoTdaoYet()
        public
        registerAmbassador
        createDao
    {
        assertEq(referralGateway.collectedFees(), 0);

        uint256 expectedParentReward = (CONTRIBUTION_AMOUNT * LAYER_ONE_REWARD_RATIO) / 100;

        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(ambassador, child, CONTRIBUTION_AMOUNT);
        referralGateway.prePayment(ambassador, CONTRIBUTION_AMOUNT, tDaoName);

        uint256 fees = (CONTRIBUTION_AMOUNT * referralGateway.SERVICE_FEE_RATIO()) / 100;
        uint256 collectedFees = fees - expectedParentReward;

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 4_500_000);
        assertEq(referralGateway.parentRewardsByChild(ambassador, child), expectedParentReward);
        assertEq(expectedParentReward, 1_000_000);
    }

    function testPrePaymentParentAmbassadorChildrenKYCedNoTdaoYet()
        public
        registerAmbassador
        kycChild
        createDao
    {
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(usdc.balanceOf(ambassador), 0);

        uint256 expectedParentReward = (CONTRIBUTION_AMOUNT * LAYER_ONE_REWARD_RATIO) / 100;

        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnParentRewarded(ambassador, child, expectedParentReward);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(ambassador, child, CONTRIBUTION_AMOUNT);

        referralGateway.prePayment(ambassador, CONTRIBUTION_AMOUNT, tDaoName);

        uint256 fees = (CONTRIBUTION_AMOUNT * referralGateway.SERVICE_FEE_RATIO()) / 100;
        uint256 collectedFees = fees - expectedParentReward;

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 4_500_000);
        assertEq(referralGateway.parentRewardsByChild(ambassador, child), 0);
        assertEq(expectedParentReward, 1_000_000);
        assertEq(usdc.balanceOf(ambassador), expectedParentReward);
    }

    modifier prepayment() {
        vm.prank(child);
        referralGateway.prePayment(ambassador, CONTRIBUTION_AMOUNT, tDaoName);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                  JOIN
    //////////////////////////////////////////////////////////////*/

    function testMustRevertJoinPoolIfTheDaoHasNoAssignedAddressYet()
        public
        registerAmbassador
        kycChild
        createDao
        prepayment
    {
        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAOAddressNotAssignedYet.selector);
        emit OnMemberJoined(2, child);
        referralGateway.joinDao(child);
    }

    function testMustRevertJoinPoolIfTheChildIsNotKYC()
        public
        createDao
        assignTDAOAddress
        registerAmbassador
        prepayment
    {
        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__NotKYCed.selector);
        emit OnMemberJoined(2, child);
        referralGateway.joinDao(child);
    }

    function testMustRevertJoinPoolIfTheChildIsNotAllowedToPreJoin()
        public
        createDao
        assignTDAOAddress
        registerAmbassador
        kycChild
        prepayment
    {
        vm.prank(daoAdmin);
        referralGateway.setPreJoinEnabled(tDaoName, false);

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__NotAllowedToPrePay.selector);
        emit OnMemberJoined(2, child);
        referralGateway.joinDao(child);
    }

    function testJoinPool()
        public
        createDao
        assignTDAOAddress
        registerAmbassador
        kycChild
        prepayment
    {
        uint256 referralGatewayInitialBalance = usdc.balanceOf(address(referralGateway));
        uint256 takasurePoolInitialBalance = usdc.balanceOf(address(takasurePool));

        vm.prank(takadao);
        vm.expectEmit(true, true, false, false, address(takasurePool));
        emit OnMemberJoined(2, child);
        referralGateway.joinDao(child);

        uint256 referralGatewayFinalBalance = usdc.balanceOf(address(referralGateway));
        uint256 takasurePoolFinalBalance = usdc.balanceOf(address(takasurePool));

        assert(referralGatewayFinalBalance < referralGatewayInitialBalance);
        assert(takasurePoolFinalBalance > takasurePoolInitialBalance);
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function testWithdrawFees()
        public
        createDao
        assignTDAOAddress
        registerAmbassador
        kycChild
        prepayment
    {
        uint256 referralGatewayInitialBalance = usdc.balanceOf(address(referralGateway));
        uint256 collectedFees = referralGateway.collectedFees();
        uint256 takadaoInitialBalance = usdc.balanceOf(address(takadao));

        vm.prank(takadao);
        referralGateway.withdrawFees();

        uint256 referralGatewayFinalBalance = usdc.balanceOf(address(referralGateway));
        uint256 takadaoFinalBalance = usdc.balanceOf(address(takadao));

        assertEq(referralGatewayFinalBalance, referralGatewayInitialBalance - collectedFees);
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(takadaoFinalBalance, takadaoInitialBalance + collectedFees);
    }

    /*//////////////////////////////////////////////////////////////
                              GRANDPARENTS
    //////////////////////////////////////////////////////////////*/

    function testCompleteReferralTree() public createDao assignTDAOAddress {
        // Parents addresses
        address parentTier1 = makeAddr("parentTier1");
        address parentTier2 = makeAddr("parentTier2");
        address parentTier3 = makeAddr("parentTier3");
        address parentTier4 = makeAddr("parentTier4");

        address[4] memory parents = [parentTier1, parentTier2, parentTier3, parentTier4];

        for (uint i = 0; i < parents.length; i++) {
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

        // Now parent 1 refer parent 2, this refer parent 3, this refer parent 4 and this refer the child
        vm.startPrank(takadao);
        referralGateway.setKYCStatus(parentTier1);
        referralGateway.setKYCStatus(parentTier2);
        referralGateway.setKYCStatus(parentTier3);
        referralGateway.setKYCStatus(parentTier4);
        referralGateway.setKYCStatus(childWithoutReferee);
        vm.stopPrank();

        // Parent 2 prepay referred by parent 1
        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;
        // The expected parent 1 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentOneReward = (parentTier2Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        vm.prank(parentTier2);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnParentRewarded(parentTier1, parentTier2, expectedParentOneReward);
        referralGateway.prePayment(parentTier1, parentTier2Contribution, tDaoName);

        // Parent 3 prepay referred by parent 2
        uint256 parentTier3Contribution = 2 * CONTRIBUTION_AMOUNT;
        // The expected parent 2 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentTwoReward = (parentTier3Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 1% of the parent 2 contribution
        expectedParentOneReward = (parentTier3Contribution * LAYER_TWO_REWARD_RATIO) / 100;

        vm.prank(parentTier3);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnParentRewarded(parentTier2, parentTier3, expectedParentTwoReward);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnParentRewarded(parentTier1, parentTier3, expectedParentOneReward);
        referralGateway.prePayment(parentTier2, parentTier3Contribution, tDaoName);

        // Parent 4 prepay referred by parent 3
        uint256 parentTier4Contribution = 7 * CONTRIBUTION_AMOUNT;
        // The expected parent 3 reward ratio will be 4% of the parent 4 contribution
        uint256 expectedParentThreeReward = (parentTier4Contribution * LAYER_ONE_REWARD_RATIO) /
            100;
        // The expected parent 2 reward ratio will be 1% of the parent 4 contribution
        expectedParentTwoReward = (parentTier4Contribution * LAYER_TWO_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 0.35% of the parent 4 contribution
        expectedParentOneReward = (parentTier4Contribution * LAYER_THREE_REWARD_RATIO) / 10000;

        vm.prank(parentTier4);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnParentRewarded(parentTier3, parentTier4, expectedParentThreeReward);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnParentRewarded(parentTier2, parentTier4, expectedParentTwoReward);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnParentRewarded(parentTier1, parentTier4, expectedParentOneReward);
        referralGateway.prePayment(parentTier3, parentTier4Contribution, tDaoName);

        // Parent 4 prepay referred by parent 3
        uint256 childWithoutRefereeContribution = 4 * CONTRIBUTION_AMOUNT;
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

        vm.prank(childWithoutReferee);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnParentRewarded(parentTier4, childWithoutReferee, expectedParentFourReward);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnParentRewarded(parentTier3, childWithoutReferee, expectedParentThreeReward);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnParentRewarded(parentTier2, childWithoutReferee, expectedParentTwoReward);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnParentRewarded(parentTier1, childWithoutReferee, expectedParentOneReward);
        referralGateway.prePayment(parentTier4, childWithoutRefereeContribution, tDaoName);
    }

    function testLayersCorrectlyAssigned() public createDao assignTDAOAddress {
        // Parents addresses
        address parentTier1 = makeAddr("parentTier1");
        address parentTier2 = makeAddr("parentTier2");
        address parentTier3 = makeAddr("parentTier3");
        address parentTier4 = makeAddr("parentTier4");
        address[4] memory parents = [parentTier1, parentTier2, parentTier3, parentTier4];
        for (uint i = 0; i < parents.length; i++) {
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

        // Now parent 1 refer parent 2, this refer parent 3, this refer parent 4 and this refer the child
        // In this test we will not kyc anyone

        // Parent 2 prepay referred by parent 1
        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;

        // The expected parent 1 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentOneReward = (parentTier2Contribution * LAYER_ONE_REWARD_RATIO) / 100;

        vm.prank(parentTier2);
        referralGateway.prePayment(parentTier1, parentTier2Contribution, tDaoName);

        assertEq(
            referralGateway.parentRewardsByChild(parentTier1, parentTier2),
            expectedParentOneReward
        );
        assertEq(referralGateway.parentRewardsByLayer(parentTier1, 1), expectedParentOneReward);

        // Parent 3 prepay referred by parent 2
        uint256 parentTier3Contribution = 2 * CONTRIBUTION_AMOUNT;
        // The expected parent 2 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentTwoReward = (parentTier3Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        // // The expected parent 1 reward ratio will be 1% of the parent 2 contribution
        expectedParentOneReward = (parentTier3Contribution * LAYER_TWO_REWARD_RATIO) / 100;

        vm.prank(parentTier3);
        referralGateway.prePayment(parentTier2, parentTier3Contribution, tDaoName);

        assertEq(
            referralGateway.parentRewardsByChild(parentTier2, parentTier3),
            expectedParentTwoReward
        );
        assertEq(referralGateway.parentRewardsByLayer(parentTier2, 1), expectedParentTwoReward);
        assertEq(referralGateway.parentRewardsByLayer(parentTier1, 2), expectedParentOneReward);

        // Parent 4 prepay referred by parent 3
        uint256 parentTier4Contribution = 7 * CONTRIBUTION_AMOUNT;
        // The expected parent 3 reward ratio will be 4% of the parent 4 contribution
        uint256 expectedParentThreeReward = (parentTier4Contribution * LAYER_ONE_REWARD_RATIO) /
            100;
        // The expected parent 2 reward ratio will be 1% of the parent 4 contribution
        expectedParentTwoReward = (parentTier4Contribution * LAYER_TWO_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 0.35% of the parent 4 contribution
        expectedParentOneReward = (parentTier4Contribution * LAYER_THREE_REWARD_RATIO) / 10000;

        vm.prank(parentTier4);
        referralGateway.prePayment(parentTier3, parentTier4Contribution, tDaoName);

        assertEq(
            referralGateway.parentRewardsByChild(parentTier3, parentTier4),
            expectedParentThreeReward
        );
        assertEq(referralGateway.parentRewardsByLayer(parentTier3, 1), expectedParentThreeReward);
        assertEq(referralGateway.parentRewardsByLayer(parentTier2, 2), expectedParentTwoReward);
        assertEq(referralGateway.parentRewardsByLayer(parentTier1, 3), expectedParentOneReward);

        // Parent 4 prepay referred by parent 3
        // The expected parent 4 reward ratio will be 4% of the child without referee contribution
        uint256 expectedParentFourReward = (CONTRIBUTION_AMOUNT * LAYER_ONE_REWARD_RATIO) / 100;
        // The expected parent 3 reward ratio will be 1% of the child without referee
        expectedParentThreeReward = (CONTRIBUTION_AMOUNT * LAYER_TWO_REWARD_RATIO) / 100;
        // The expected parent 2 reward ratio will be 0.35% of the child without referee contribution
        expectedParentTwoReward = (CONTRIBUTION_AMOUNT * LAYER_THREE_REWARD_RATIO) / 10000;
        // The expected parent 1 reward ratio will be 0.175% of the child without referee contribution
        expectedParentOneReward = (CONTRIBUTION_AMOUNT * LAYER_FOUR_REWARD_RATIO) / 100000;

        vm.prank(childWithoutReferee);
        referralGateway.prePayment(parentTier4, CONTRIBUTION_AMOUNT, tDaoName);

        assertEq(
            referralGateway.parentRewardsByChild(parentTier4, childWithoutReferee),
            expectedParentFourReward
        );
        assertEq(referralGateway.parentRewardsByLayer(parentTier4, 1), expectedParentFourReward);
        assertEq(referralGateway.parentRewardsByLayer(parentTier3, 2), expectedParentThreeReward);
        assertEq(referralGateway.parentRewardsByLayer(parentTier2, 3), expectedParentTwoReward);
        assertEq(referralGateway.parentRewardsByLayer(parentTier1, 4), expectedParentOneReward);
    }
}
