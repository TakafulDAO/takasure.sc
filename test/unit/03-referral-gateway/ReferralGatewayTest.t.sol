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

    bytes32 private constant AMBASSADOR = keccak256("AMBASSADOR");

    event OnPreJoinEnabledChanged(bool indexed isPreJoinEnabled);
    event OnNewAmbassadorProposal(address indexed proposedAmbassador);
    event OnNewAmbassador(address indexed ambassador);
    event OnPrePayment(address indexed parent, address indexed child, uint256 indexed contribution);
    event OnMemberJoined(uint256 indexed memberId, address indexed member);
    event OnNewDaoCreated(string indexed daoName);

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

    function testSetNewRewardRatios() public {
        uint8 newMemberRatio = 5;
        uint8 newAmbassadorRatio = 10;

        assertNotEq(referralGateway.memberRewardRatio(), newMemberRatio);
        assertNotEq(referralGateway.ambassadorRewardRatio(), newAmbassadorRatio);

        vm.startPrank(takadao);
        referralGateway.setNewMemberRewardRatio(newMemberRatio);
        referralGateway.setNewAmbassadorRewardRatio(newAmbassadorRatio);
        vm.stopPrank();

        assertEq(referralGateway.memberRewardRatio(), newMemberRatio);
        assertEq(referralGateway.ambassadorRewardRatio(), newAmbassadorRatio);
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
        assertEq(referralGateway.childCounter(), 0);

        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(ambassador, child, CONTRIBUTION_AMOUNT);
        referralGateway.prePayment(ambassador, CONTRIBUTION_AMOUNT, tDaoName);

        uint256 fees = (CONTRIBUTION_AMOUNT * referralGateway.SERVICE_FEE()) / 100;
        uint256 parentReward = (fees * referralGateway.ambassadorRewardRatio()) / 100;
        uint256 collectedFees = fees - parentReward;

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 4_750_000);
        assertEq(referralGateway.parentRewards(ambassador, child), parentReward);
        assertEq(parentReward, 250_000);
        assertEq(referralGateway.childCounter(), 1);
    }

    function testPrePaymentParentAmbassadorChildrenKYCedNoTdaoYet()
        public
        registerAmbassador
        kycChild
        createDao
    {
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(referralGateway.childCounter(), 0);
        assertEq(usdc.balanceOf(ambassador), 0);

        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(ambassador, child, CONTRIBUTION_AMOUNT);
        referralGateway.prePayment(ambassador, CONTRIBUTION_AMOUNT, tDaoName);

        uint256 fees = (CONTRIBUTION_AMOUNT * referralGateway.SERVICE_FEE()) / 100;
        uint256 parentReward = (fees * referralGateway.ambassadorRewardRatio()) / 100;
        uint256 collectedFees = fees - parentReward;

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 4_750_000);
        assertEq(referralGateway.parentRewards(ambassador, child), 0);
        assertEq(parentReward, 250_000);
        assertEq(usdc.balanceOf(ambassador), parentReward);
        assertEq(referralGateway.childCounter(), 1);
    }

    function testPrePaymentParentMemberChildrenNotKYCedTdaoAddressAssigned()
        public
        createDao
        assignTDAOAddress
    {
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(referralGateway.childCounter(), 0);

        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(member, child, CONTRIBUTION_AMOUNT);
        referralGateway.prePayment(member, CONTRIBUTION_AMOUNT, tDaoName);

        uint256 fees = (CONTRIBUTION_AMOUNT * referralGateway.SERVICE_FEE()) / 100;
        uint256 parentReward = (fees * referralGateway.memberRewardRatio()) / 100;
        uint256 collectedFees = fees - parentReward;

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 4_000_000);
        assertEq(referralGateway.parentRewards(member, child), parentReward);
        assertEq(parentReward, 1_000_000);
        assertEq(referralGateway.childCounter(), 1);
    }

    function testPrePaymentParentMemberChildrenKYCedTdaoAddressAssigned()
        public
        kycChild
        createDao
        assignTDAOAddress
    {
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(referralGateway.childCounter(), 0);
        assertEq(usdc.balanceOf(member), USDC_INITIAL_AMOUNT - CONTRIBUTION_AMOUNT);
        assertEq(usdc.balanceOf(address(takasurePool)), (CONTRIBUTION_AMOUNT * (100 - 22)) / 100);

        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(member, child, CONTRIBUTION_AMOUNT);
        referralGateway.prePayment(member, CONTRIBUTION_AMOUNT, tDaoName);

        uint256 fees = (CONTRIBUTION_AMOUNT * referralGateway.SERVICE_FEE()) / 100;
        uint256 parentReward = (fees * referralGateway.memberRewardRatio()) / 100;
        uint256 collectedFees = fees - parentReward;

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 4_000_000);
        assertEq(referralGateway.parentRewards(member, child), 0);
        assertEq(parentReward, 1_000_000);
        assertEq(usdc.balanceOf(member), USDC_INITIAL_AMOUNT - CONTRIBUTION_AMOUNT + parentReward);
        assertEq(referralGateway.childCounter(), 1);
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
        referralGateway.joinDao();
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
        referralGateway.joinDao();
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
        referralGateway.joinDao();
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

        vm.prank(child);
        vm.expectEmit(true, true, false, false, address(takasurePool));
        emit OnMemberJoined(2, child);
        referralGateway.joinDao();

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
        uint256 testContribution = 150e6; // 150 USDC
        // Parents addresses
        address parentTier1 = makeAddr("parentTier1");
        address parentTier2 = makeAddr("parentTier2");
        address parentTier3 = makeAddr("parentTier3");
        address parentTier4 = makeAddr("parentTier4");

        address[4] memory parents = [parentTier1, parentTier2, parentTier3, parentTier4];

        for (uint i = 0; i < parents.length; i++) {
            // Give USDC to parents
            deal(address(usdc), parents[i], 2 * testContribution);
            // Approve the contracts
            vm.startPrank(parents[i]);
            usdc.approve(address(takasurePool), 2 * testContribution);
            usdc.approve(address(referralGateway), 2 * testContribution);
            vm.stopPrank();

            vm.prank(admin);
            takasurePool.setKYCStatus(parents[i]);

            // We simulate a request before the KYC
            _successResponse(address(bmConsumerMock));

            vm.prank(parents[i]);
            takasurePool.joinPool(CONTRIBUTION_AMOUNT, 5);
        }

        address childWithoutReferee = makeAddr("childWithoutReferee");

        deal(address(usdc), childWithoutReferee, 2 * testContribution);
        vm.prank(childWithoutReferee);
        usdc.approve(address(referralGateway), 2 * testContribution);

        // Now parent 1 refer parent 2, this refer parent 3, this refer parent 4 and this refer the child
        vm.startPrank(takadao);
        referralGateway.setKYCStatus(parentTier1);
        referralGateway.setKYCStatus(parentTier2);
        referralGateway.setKYCStatus(parentTier3);
        referralGateway.setKYCStatus(parentTier4);
        referralGateway.setKYCStatus(childWithoutReferee);
        vm.stopPrank();

        vm.prank(parentTier2);
        referralGateway.prePayment(parentTier1, testContribution, tDaoName);

        /*
        - Contribution 150_000_000 USDC
        - Fees 30_000_000 USDC
        - Parent 1 reward 6_000_000 USDC
        - Collected fees 24_000_000 USDC
        */
        uint256 expectedCollectedFees = 24_000_000;
        uint256 expectedParentReward_1 = 6_000_000;

        assertEq(referralGateway.collectedFees(), expectedCollectedFees);
        assertEq(
            usdc.balanceOf(parentTier1),
            (2 * testContribution) - CONTRIBUTION_AMOUNT + expectedParentReward_1
        );

        vm.prank(parentTier3);
        referralGateway.prePayment(parentTier2, 100_000_000, tDaoName);

        /*
        - Contribution 100_000_000 USDC
        - Fees 20_000_000 USDC
        - Parent 2 reward 4_000_000 USDC
        - Parent 1 reward 800_000 USDC, Total 6_800_000 USDC
        - Collected fees 15_200_000 USDC
        - Total collected fees 39_200_000 USDC
        */
        expectedCollectedFees += 15_200_000;
        expectedParentReward_1 = 6_800_000;
        uint256 expectedParentReward_2 = 4_000_000;

        assertEq(referralGateway.collectedFees(), expectedCollectedFees);
        assertEq(
            usdc.balanceOf(parentTier1),
            (2 * testContribution) - CONTRIBUTION_AMOUNT + expectedParentReward_1
        );
        assertEq(
            usdc.balanceOf(parentTier2),
            testContribution - CONTRIBUTION_AMOUNT + expectedParentReward_2
        );

        vm.prank(parentTier4);
        referralGateway.prePayment(parentTier3, 200_000_000, tDaoName);

        /*
        - Contribution 200_000_000 USDC
        - Fees 40_000_000 USDC
        - Parent 3 reward 8_000_000 USDC
        - Parent 2 reward 1_600_000 USDC, Total 5_600_000 USDC
        - Parent 1 reward 320_000 USDC, Total 7_120_000 USDC
        - Collected fees 30_080_000 USDC
        - Total collected fees 69_280_000 USDC
        */
        expectedCollectedFees += 30_080_000;
        expectedParentReward_1 = 7_120_000;
        expectedParentReward_2 = 5_600_000;
        uint256 expectedParentReward_3 = 8_000_000;

        assertEq(referralGateway.collectedFees(), expectedCollectedFees);
        assertEq(
            usdc.balanceOf(parentTier1),
            (2 * testContribution) - CONTRIBUTION_AMOUNT + expectedParentReward_1
        );
        assertEq(
            usdc.balanceOf(parentTier2),
            testContribution - CONTRIBUTION_AMOUNT + expectedParentReward_2
        );
        assertEq(
            usdc.balanceOf(parentTier3),
            (2 * testContribution) - CONTRIBUTION_AMOUNT - 100_000_000 + expectedParentReward_3
        );

        vm.prank(childWithoutReferee);
        referralGateway.prePayment(parentTier4, 200_000_000, tDaoName);

        /*
        - Contribution 200_000_000 USDC
        - Fees 40_000_000 USDC
        - Parent 4 reward 8_000_000 USDC
        - Parent 3 reward 1_600_000 USDC, Total 9_600_000 USDC
        - Parent 2 reward 320_000 USDC, Total 5_920_000 USDC
        - Parent 1 reward 64_000 USDC, Total 7_184_000 USDC
        - Collected fees 30_016_000 USDC
        - Total collected fees 99_296_000 USDC
        */
        expectedCollectedFees += 30_016_000;
        expectedParentReward_1 = 7_184_000;
        expectedParentReward_2 = 5_920_000;
        expectedParentReward_3 = 9_600_000;
        uint256 expectedParentReward_4 = 8_000_000;

        assertEq(referralGateway.collectedFees(), expectedCollectedFees);
        assertEq(
            usdc.balanceOf(parentTier1),
            (2 * testContribution) - CONTRIBUTION_AMOUNT + expectedParentReward_1
        );
        assertEq(
            usdc.balanceOf(parentTier2),
            testContribution - CONTRIBUTION_AMOUNT + expectedParentReward_2
        );
        assertEq(usdc.balanceOf(parentTier3), 175_000_000 + expectedParentReward_3);
        assertEq(usdc.balanceOf(parentTier4), 75_000_000 + expectedParentReward_4);
    }
}
