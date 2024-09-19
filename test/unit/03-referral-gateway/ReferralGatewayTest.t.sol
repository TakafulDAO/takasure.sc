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
    address ambassador = makeAddr("ambassador");
    address member = makeAddr("member");
    address notMember = makeAddr("notMember");
    address child = makeAddr("child");
    string tDAOName = "TheLifeDao";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC

    bytes32 private constant AMBASSADOR = keccak256("AMBASSADOR");

    event OnPreJoinEnabledChanged(bool indexed isPreJoinEnabled);
    event OnNewAmbassadorProposal(address indexed proposedAmbassador);
    event OnNewAmbassador(address indexed ambassador);
    event OnPrePayment(address indexed parent, address indexed child, uint256 indexed contribution);
    event OnMemberJoined(uint256 indexed memberId, address indexed member);

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
                                SETTERS
    //////////////////////////////////////////////////////////////*/
    function testSetIsPreJoinEnabled() public {
        assert(referralGateway.isPreJoinEnabled());

        vm.prank(takadao);
        vm.expectEmit(true, false, false, false, address(referralGateway));
        emit OnPreJoinEnabledChanged(false);
        referralGateway.setPreJoinEnabled(false);

        assert(!referralGateway.isPreJoinEnabled());
    }

    function testAssignTDAOAddress() public {
        assertEq(referralGateway.tDAOs(tDAOName), address(0));
        vm.prank(takadao);
        referralGateway.assignTDaoAddress(tDAOName, address(takasurePool));
        assertEq(referralGateway.tDAOs(tDAOName), address(takasurePool));
    }

    function testSetNewRewardRatios() public {
        uint8 newDefaultRatio = 2;
        uint8 newMemberRatio = 5;
        uint8 newAmbassadorRatio = 10;

        assertNotEq(referralGateway.defaultRewardRatio(), newDefaultRatio);
        assertNotEq(referralGateway.memberRewardRatio(), newMemberRatio);
        assertNotEq(referralGateway.ambassadorRewardRatio(), newAmbassadorRatio);

        vm.startPrank(takadao);
        referralGateway.setNewDefaultRewardRatio(newDefaultRatio);
        referralGateway.setNewMemberRewardRatio(newMemberRatio);
        referralGateway.setNewAmbassadorRewardRatio(newAmbassadorRatio);
        vm.stopPrank();

        assertEq(referralGateway.defaultRewardRatio(), newDefaultRatio);
        assertEq(referralGateway.memberRewardRatio(), newMemberRatio);
        assertEq(referralGateway.ambassadorRewardRatio(), newAmbassadorRatio);
    }

    modifier assignTDAOAddress() {
        vm.prank(takadao);
        referralGateway.assignTDaoAddress(tDAOName, address(takasurePool));
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    function testPropossedAmbassadorMustRevertIfIsAddressZero() public {
        vm.prank(takadao);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.proposeAsAmbassador(address(0));
    }

    function testApproveAmbassadorMustRevertIfIsAddressZero() public {
        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.approveAsAmbassador(address(0));
    }

    function testMustRevertIfAmbassadorIsNotPreviouslyProposed() public {
        vm.prank(takadao);
        vm.expectRevert(ReferralGateway.ReferralGateway__OnlyProposedAmbassadors.selector);
        referralGateway.approveAsAmbassador(ambassador);
    }

    function testMustRevertIfPrePaymentIsDisabled() public {
        vm.prank(takadao);
        referralGateway.setPreJoinEnabled(false);

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__NotAllowedToPrePay.selector);
        referralGateway.prePaymentWithReferral(ambassador, 25e6, tDAOName);
    }

    function testMustRevertIfPrePaymentContributionIsOutOfRange() public {
        vm.startPrank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__ContributionOutOfRange.selector);
        referralGateway.prePaymentWithReferral(ambassador, 20e6, tDAOName);

        vm.expectRevert(ReferralGateway.ReferralGateway__ContributionOutOfRange.selector);
        referralGateway.prePaymentWithReferral(ambassador, 300e6, tDAOName);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              AMBASSADORS
    //////////////////////////////////////////////////////////////*/

    function testProposeAsAmbassadorCalledByOther() public {
        assert(!referralGateway.proposedAmbassadors(ambassador));
        vm.prank(takadao);
        vm.expectEmit(true, false, false, false, address(referralGateway));
        emit OnNewAmbassadorProposal(ambassador);
        referralGateway.proposeAsAmbassador(ambassador);

        assert(referralGateway.proposedAmbassadors(ambassador));
    }

    function testProposeAsAmbassadorCalledBySelf() public {
        assert(!referralGateway.proposedAmbassadors(ambassador));
        vm.prank(ambassador);
        vm.expectEmit(true, false, false, false, address(referralGateway));
        emit OnNewAmbassadorProposal(ambassador);
        referralGateway.proposeAsAmbassador();

        assert(referralGateway.proposedAmbassadors(ambassador));
    }

    modifier proposeAsAmbassador() {
        vm.prank(takadao);
        referralGateway.proposeAsAmbassador(ambassador);
        _;
    }

    function testApproveAsAmbassador() public proposeAsAmbassador {
        assert(!referralGateway.hasRole(AMBASSADOR, ambassador));
        vm.prank(takadao);
        vm.expectEmit(true, false, false, false, address(referralGateway));
        emit OnNewAmbassador(ambassador);
        referralGateway.approveAsAmbassador(ambassador);

        assert(referralGateway.hasRole(AMBASSADOR, ambassador));
    }

    modifier approveAsAmbassador() {
        vm.startPrank(takadao);
        referralGateway.proposeAsAmbassador(ambassador);
        referralGateway.approveAsAmbassador(ambassador);
        vm.stopPrank();
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

    modifier kycChild() {
        vm.prank(kycProvider);
        referralGateway.setKYCStatus(child);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                PREPAYS
    //////////////////////////////////////////////////////////////*/

    function testPrePaymentParentAmbassadorChildrenNotKYCedNoTdaoYet() public approveAsAmbassador {
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(referralGateway.childCounter(), 0);

        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(ambassador, child, CONTRIBUTION_AMOUNT);
        referralGateway.prePaymentWithReferral(ambassador, CONTRIBUTION_AMOUNT, tDAOName);

        uint256 fees = (CONTRIBUTION_AMOUNT * 22) / 100; // 25000000 * 22 / 100 = 5500000
        uint256 parentReward = (fees * 5) / 100; // 5500000 * 5 / 100 = 275000
        uint256 collectedFees = fees - parentReward;

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 5_225_000);
        assertEq(referralGateway.parentRewards(ambassador, child), parentReward);
        assertEq(parentReward, 275_000);
        assertEq(referralGateway.childCounter(), 1);
    }

    function testPrePaymentParentAmbassadorChildrenKYCedNoTdaoYet()
        public
        approveAsAmbassador
        kycChild
    {
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(referralGateway.childCounter(), 0);
        assertEq(usdc.balanceOf(ambassador), 0);

        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(ambassador, child, CONTRIBUTION_AMOUNT);
        referralGateway.prePaymentWithReferral(ambassador, CONTRIBUTION_AMOUNT, tDAOName);

        uint256 fees = (CONTRIBUTION_AMOUNT * 22) / 100; // 25000000 * 22 / 100 = 5500000
        uint256 parentReward = (fees * 5) / 100; // 5500000 * 5 / 100 = 275000
        uint256 collectedFees = fees - parentReward;

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 5_225_000);
        assertEq(referralGateway.parentRewards(ambassador, child), 0);
        assertEq(parentReward, 275_000);
        assertEq(usdc.balanceOf(ambassador), parentReward);
        assertEq(referralGateway.childCounter(), 1);
    }

    function testPrePaymentParentMemberChildrenNotKYCedNoTdaoYet() public {
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(referralGateway.childCounter(), 0);

        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(member, child, CONTRIBUTION_AMOUNT);
        referralGateway.prePaymentWithReferral(member, CONTRIBUTION_AMOUNT, tDAOName);

        uint256 fees = (CONTRIBUTION_AMOUNT * 22) / 100; // 25000000 * 22 / 100 = 5500000
        uint256 parentReward = (fees * 1) / 100; // 5500000 * 1 / 100 = 55000
        uint256 collectedFees = fees - parentReward;

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 5_445_000);
        assertEq(referralGateway.parentRewards(member, child), parentReward);
        assertEq(parentReward, 55_000);
        assertEq(referralGateway.childCounter(), 1);
    }

    function testPrePaymentParentMemberChildrenKYCedNoTdaoYet() public kycChild {
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(referralGateway.childCounter(), 0);
        assertEq(usdc.balanceOf(member), USDC_INITIAL_AMOUNT - CONTRIBUTION_AMOUNT);

        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(member, child, CONTRIBUTION_AMOUNT);
        referralGateway.prePaymentWithReferral(member, CONTRIBUTION_AMOUNT, tDAOName);

        uint256 fees = (CONTRIBUTION_AMOUNT * 22) / 100; // 25000000 * 22 / 100 = 5500000
        uint256 parentReward = (fees * 1) / 100; // 5500000 * 1 / 100 = 55000
        uint256 collectedFees = fees - parentReward;

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 5_445_000);
        assertEq(referralGateway.parentRewards(member, child), 0);
        assertEq(parentReward, 55_000);
        assertEq(usdc.balanceOf(member), USDC_INITIAL_AMOUNT - CONTRIBUTION_AMOUNT + parentReward);
        assertEq(referralGateway.childCounter(), 1);
    }

    function testPrePaymentParentMemberChildrenNotKYCedTdaoAddressAssigned()
        public
        assignTDAOAddress
    {
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(referralGateway.childCounter(), 0);

        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(member, child, CONTRIBUTION_AMOUNT);
        referralGateway.prePaymentWithReferral(member, CONTRIBUTION_AMOUNT, tDAOName);

        uint256 fees = (CONTRIBUTION_AMOUNT * 22) / 100; // 25000000 * 22 / 100 = 5500000
        uint256 parentReward = (fees * 2) / 100; // 5500000 * 2 / 100 = 110000
        uint256 collectedFees = fees - parentReward;

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 5_390_000);
        assertEq(referralGateway.parentRewards(member, child), parentReward);
        assertEq(parentReward, 110_000);
        assertEq(referralGateway.childCounter(), 1);
    }

    function testPrePaymentParentMemberChildrenKYCedTdaoAddressAssigned()
        public
        kycChild
        assignTDAOAddress
    {
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(referralGateway.childCounter(), 0);
        assertEq(usdc.balanceOf(member), USDC_INITIAL_AMOUNT - CONTRIBUTION_AMOUNT);
        assertEq(usdc.balanceOf(address(takasurePool)), (CONTRIBUTION_AMOUNT * (100 - 22)) / 100);

        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(member, child, CONTRIBUTION_AMOUNT);
        referralGateway.prePaymentWithReferral(member, CONTRIBUTION_AMOUNT, tDAOName);

        uint256 fees = (CONTRIBUTION_AMOUNT * 22) / 100; // 25000000 * 22 / 100 = 5500000
        uint256 parentReward = (fees * 2) / 100; // 5500000 * 2 / 100 = 110000
        uint256 collectedFees = fees - parentReward;

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 5_390_000);
        assertEq(referralGateway.parentRewards(member, child), 0);
        assertEq(parentReward, 110_000);
        assertEq(usdc.balanceOf(member), USDC_INITIAL_AMOUNT - CONTRIBUTION_AMOUNT + parentReward);
        assertEq(referralGateway.childCounter(), 1);
    }

    function testPrePaymentParentNotMemberChildrenNotKYCedNoTdaoYet() public {
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(referralGateway.childCounter(), 0);

        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(notMember, child, CONTRIBUTION_AMOUNT);
        referralGateway.prePaymentWithReferral(notMember, CONTRIBUTION_AMOUNT, tDAOName);

        uint256 fees = (CONTRIBUTION_AMOUNT * 22) / 100; // 25000000 * 22 / 100 = 5500000
        uint256 parentReward = (fees * 1) / 100; // 5500000 * 1 / 100 = 55000
        uint256 collectedFees = fees - parentReward;

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 5_445_000);
        assertEq(referralGateway.parentRewards(notMember, child), parentReward);
        assertEq(parentReward, 55_000);
        assertEq(referralGateway.childCounter(), 1);
    }

    function testPrePaymentParentNotMemberChildrenKYCedNoTdaoYet() public kycChild {
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(referralGateway.childCounter(), 0);
        assertEq(usdc.balanceOf(notMember), 0);

        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(notMember, child, CONTRIBUTION_AMOUNT);
        referralGateway.prePaymentWithReferral(notMember, CONTRIBUTION_AMOUNT, tDAOName);

        uint256 fees = (CONTRIBUTION_AMOUNT * 22) / 100; // 25000000 * 22 / 100 = 5500000
        uint256 parentReward = (fees * 1) / 100; // 5500000 * 1 / 100 = 55000
        uint256 collectedFees = fees - parentReward;

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 5_445_000);
        assertEq(referralGateway.parentRewards(notMember, child), 0);
        assertEq(parentReward, 55_000);
        assertEq(usdc.balanceOf(notMember), parentReward);
        assertEq(referralGateway.childCounter(), 1);
    }

    function testPrePaymentParentNotMemberChildrenNotKYCedTdaoAddressAssigned()
        public
        assignTDAOAddress
    {
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(referralGateway.childCounter(), 0);

        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(notMember, child, CONTRIBUTION_AMOUNT);
        referralGateway.prePaymentWithReferral(notMember, CONTRIBUTION_AMOUNT, tDAOName);

        uint256 fees = (CONTRIBUTION_AMOUNT * 22) / 100; // 25000000 * 22 / 100 = 5500000
        uint256 parentReward = (fees * 1) / 100; // 5500000 * 2 / 100 = 55000
        uint256 collectedFees = fees - parentReward;

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 5_445_000);
        assertEq(referralGateway.parentRewards(notMember, child), parentReward);
        assertEq(parentReward, 55_000);
        assertEq(referralGateway.childCounter(), 1);
    }

    function testPrePaymentParentNotMemberChildrenKYCedTdaoAddressAssigned()
        public
        kycChild
        assignTDAOAddress
    {
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(referralGateway.childCounter(), 0);
        assertEq(usdc.balanceOf(notMember), 0);
        assertEq(usdc.balanceOf(address(takasurePool)), (CONTRIBUTION_AMOUNT * (100 - 22)) / 100);

        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(notMember, child, CONTRIBUTION_AMOUNT);
        referralGateway.prePaymentWithReferral(notMember, CONTRIBUTION_AMOUNT, tDAOName);

        uint256 fees = (CONTRIBUTION_AMOUNT * 22) / 100; // 25000000 * 22 / 100 = 5500000
        uint256 parentReward = (fees * 1) / 100; // 5500000 * 1 / 100 = 55000
        uint256 collectedFees = fees - parentReward;

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 5_445_000);
        assertEq(referralGateway.parentRewards(notMember, child), 0);
        assertEq(parentReward, 55_000);
        assertEq(usdc.balanceOf(notMember), parentReward);
        assertEq(referralGateway.childCounter(), 1);
    }

    modifier prepayment() {
        vm.prank(child);
        referralGateway.prePaymentWithReferral(ambassador, CONTRIBUTION_AMOUNT, tDAOName);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                  JOIN
    //////////////////////////////////////////////////////////////*/

    function testJoinPool() public assignTDAOAddress approveAsAmbassador kycChild prepayment {
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

    function testWithdrawFees() public assignTDAOAddress approveAsAmbassador kycChild prepayment {
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
}
