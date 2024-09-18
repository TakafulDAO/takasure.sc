// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployReferralGateway} from "test/utils/TestDeployReferralGateway.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ReferralGatewayTest is Test {
    TestDeployReferralGateway deployer;
    ReferralGateway referralGateway;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address proxy;
    address takadao;
    address kycProvider;
    address ambassador = makeAddr("ambassador");
    address member = makeAddr("member");
    address child = makeAddr("child");
    address tDAO = makeAddr("tDAO");
    string tDAOName = "TheLifeDao";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC

    bytes32 private constant AMBASSADOR = keccak256("AMBASSADOR");
    bytes32 private constant MEMBER = keccak256("MEMBER");

    event OnPreJoinEnabledChanged(bool indexed isPreJoinEnabled);
    event OnNewAmbassadorProposal(address indexed proposedAmbassador);
    event OnNewAmbassador(address indexed ambassador);
    event OnPrePayment(address indexed parent, address indexed child, uint256 indexed contribution);

    function setUp() public {
        deployer = new TestDeployReferralGateway();
        (, proxy, usdcAddress, kycProvider, helperConfig) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        takadao = config.takadaoOperator;

        referralGateway = ReferralGateway(address(proxy));

        vm.prank(takadao);
        referralGateway.grantRole(MEMBER, member);

        usdc = IUSDC(usdcAddress);
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);

        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);
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
        referralGateway.assignTDaoAddress(tDAOName, tDAO);
        assertEq(referralGateway.tDAOs(tDAOName), tDAO);
    }

    modifier assignTDAOAddress() {
        vm.prank(takadao);
        referralGateway.assignTDaoAddress(tDAOName, tDAO);
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

        uint256 contribution = 25e6;
        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(ambassador, child, contribution);
        referralGateway.prePaymentWithReferral(ambassador, contribution, tDAOName);

        uint256 collectedFees = (contribution * 22) / 100; // 25000000 * 22 / 100 = 5500000
        uint256 parentReward = (collectedFees * 5) / 100; // 5500000 * 5 / 100 = 275000

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 5_500_000);
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

        uint256 contribution = 25e6;
        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(ambassador, child, contribution);
        referralGateway.prePaymentWithReferral(ambassador, contribution, tDAOName);

        uint256 collectedFees = (contribution * 22) / 100; // 25000000 * 22 / 100 = 5500000
        uint256 parentReward = (collectedFees * 5) / 100; // 5500000 * 5 / 100 = 275000

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 5_500_000);
        assertEq(referralGateway.parentRewards(ambassador, child), 0);
        assertEq(parentReward, 275_000);
        assertEq(usdc.balanceOf(ambassador), parentReward);
        assertEq(referralGateway.childCounter(), 1);
    }

    function testPrePaymentParentMemberChildrenNotKYCedNoTdaoYet() public {
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(referralGateway.childCounter(), 0);

        uint256 contribution = 25e6;
        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(member, child, contribution);
        referralGateway.prePaymentWithReferral(member, contribution, tDAOName);

        uint256 collectedFees = (contribution * 22) / 100; // 25000000 * 22 / 100 = 5500000
        uint256 parentReward = (collectedFees * 1) / 100; // 5500000 * 1 / 100 = 55000

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 5_500_000);
        assertEq(referralGateway.parentRewards(member, child), parentReward);
        assertEq(parentReward, 55_000);
        assertEq(referralGateway.childCounter(), 1);
    }

    function testPrePaymentParentMemberChildrenKYCedNoTdaoYet() public kycChild {
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(referralGateway.childCounter(), 0);
        assertEq(usdc.balanceOf(member), 0);

        uint256 contribution = 25e6;
        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(member, child, contribution);
        referralGateway.prePaymentWithReferral(member, contribution, tDAOName);

        uint256 collectedFees = (contribution * 22) / 100; // 25000000 * 22 / 100 = 5500000
        uint256 parentReward = (collectedFees * 1) / 100; // 5500000 * 1 / 100 = 55000

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 5_500_000);
        assertEq(referralGateway.parentRewards(ambassador, child), 0);
        assertEq(parentReward, 55_000);
        assertEq(usdc.balanceOf(member), parentReward);
        assertEq(referralGateway.childCounter(), 1);
    }

    function testPrePaymentParentMemberChildrenNotKYCedTdaoAddressAssigned()
        public
        assignTDAOAddress
    {
        assertEq(referralGateway.collectedFees(), 0);
        assertEq(referralGateway.childCounter(), 0);

        uint256 contribution = 25e6;
        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(member, child, contribution);
        referralGateway.prePaymentWithReferral(member, contribution, tDAOName);

        uint256 collectedFees = (contribution * 22) / 100; // 25000000 * 22 / 100 = 5500000
        uint256 parentReward = (collectedFees * 2) / 100; // 5500000 * 2 / 100 = 110000

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 5_500_000);
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
        assertEq(usdc.balanceOf(member), 0);
        assertEq(usdc.balanceOf(tDAO), 0);

        uint256 contribution = 25e6;
        vm.prank(child);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnPrePayment(member, child, contribution);
        referralGateway.prePaymentWithReferral(member, contribution, tDAOName);

        uint256 collectedFees = (contribution * 22) / 100; // 25000000 * 22 / 100 = 5500000
        uint256 parentReward = (collectedFees * 2) / 100; // 5500000 * 2 / 100 = 110000

        assertEq(referralGateway.collectedFees(), collectedFees);
        assertEq(collectedFees, 5_500_000);
        assertEq(referralGateway.parentRewards(ambassador, child), 0);
        assertEq(parentReward, 110_000);
        assertEq(usdc.balanceOf(member), parentReward);
        assertEq(referralGateway.childCounter(), 1);
    }
}
