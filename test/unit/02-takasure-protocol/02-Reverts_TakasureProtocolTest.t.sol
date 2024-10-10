// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasureReserve} from "test/utils/TestDeployTakasureReserve.s.sol";
import {DeployConsumerMocks} from "test/utils/DeployConsumerMocks.s.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/takasure/core/TakasureReserve.sol";
import {JoinModule} from "contracts/takasure/modules/JoinModule.sol";
import {MembersModule} from "contracts/takasure/modules/MembersModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureErrors} from "contracts/libraries/TakasureErrors.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract Reverts_TakasureProtocolTest is StdCheats, Test, SimulateDonResponse {
    TestDeployTakasureReserve deployer;
    DeployConsumerMocks mockDeployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    JoinModule joinModule;
    MembersModule membersModule;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address admin;
    address kycService;
    address takadao;
    address joinModuleAddress;
    address membersModuleAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public david = makeAddr("david");
    address public erin = makeAddr("erin");
    address public frank = makeAddr("frank");
    uint256 public constant USDC_INITIAL_AMOUNT = 150e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new TestDeployTakasureReserve();
        (
            takasureReserveProxy,
            joinModuleAddress,
            membersModuleAddress,
            ,
            contributionTokenAddress,
            helperConfig
        ) = deployer.run();

        joinModule = JoinModule(joinModuleAddress);
        membersModule = MembersModule(membersModuleAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        kycService = config.kycProvider;
        takadao = config.takadaoOperator;

        mockDeployer = new DeployConsumerMocks();
        bmConsumerMock = mockDeployer.run();

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);
        deal(address(usdc), bob, USDC_INITIAL_AMOUNT);
        deal(address(usdc), charlie, USDC_INITIAL_AMOUNT);
        deal(address(usdc), david, USDC_INITIAL_AMOUNT);
        deal(address(usdc), erin, USDC_INITIAL_AMOUNT);
        deal(address(usdc), frank, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(membersModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        vm.startPrank(bob);
        usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(membersModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        vm.startPrank(charlie);
        usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(membersModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        vm.startPrank(david);
        usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(membersModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        vm.startPrank(erin);
        usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(membersModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        vm.startPrank(frank);
        usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(membersModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(msg.sender);
        bmConsumerMock.setNewRequester(address(joinModuleAddress));

        vm.prank(takadao);
        joinModule.updateBmAddress();
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/
    /// @dev `setNewServiceFee` must revert if the caller is not the admin
    function testTakasureReserve_setNewServiceFeeMustRevertIfTheCallerIsNotTheAdmin() public {
        uint8 newServiceFee = 50;
        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setNewServiceFee(newServiceFee);
    }

    /// @dev `setNewServiceFee` must revert if it is higher than 35
    function testTakasureReserve_setNewServiceFeeMustRevertIfHigherThan35() public {
        uint8 newServiceFee = 36;
        vm.prank(admin);
        vm.expectRevert(TakasureErrors.TakasurePool__WrongServiceFee.selector);
        takasureReserve.setNewServiceFee(newServiceFee);
    }

    /// @dev `setNewMinimumThreshold` must revert if the caller is not the admin
    function testTakasureReserve_setNewMinimumThresholdMustRevertIfTheCallerIsNotTheAdmin() public {
        uint8 newThreshold = 50;
        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setNewMinimumThreshold(newThreshold);
    }

    /// @dev `setNewContributionToken` must revert if the caller is not the admin
    function testTakasureReserve_setNewContributionTokenMustRevertIfTheCallerIsNotTheAdmin()
        public
    {
        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setNewContributionToken(alice);
    }

    /// @dev `setNewContributionToken` must revert if the address is zero
    function testTakasureReserve_setNewContributionTokenMustRevertIfAddressZero() public {
        vm.prank(admin);
        vm.expectRevert(TakasureErrors.TakasurePool__ZeroAddress.selector);
        takasureReserve.setNewContributionToken(address(0));
    }

    /// @dev `setNewFeeClaimAddress` must revert if the caller is not the admin
    function testTakasureReserve_setNewFeeClaimAddressMustRevertIfTheCallerIsNotTheAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setNewFeeClaimAddress(alice);
    }

    /// @dev `setNewFeeClaimAddress` must revert if the address is zero
    function testTakasureReserve_setNewFeeClaimAddressMustRevertIfAddressZero() public {
        vm.prank(admin);
        vm.expectRevert(TakasureErrors.TakasurePool__ZeroAddress.selector);
        takasureReserve.setNewFeeClaimAddress(address(0));
    }

    /// @dev `setAllowCustomDuration` must revert if the caller is not the admin
    function testTakasureReserve_setAllowCustomDurationMustRevertIfTheCallerIsNotTheAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setAllowCustomDuration(true);
    }

    /// @dev `joinPool` must revert if the contribution is less than the minimum threshold
    function testJoinModule_joinPoolMustRevertIfDepositLessThanMinimum() public {
        uint256 wrongContribution = CONTRIBUTION_AMOUNT / 2;
        vm.prank(alice);
        vm.expectRevert(TakasureErrors.TakasurePool__ContributionOutOfRange.selector);
        joinModule.joinPool(wrongContribution, (5 * YEAR));
    }

    /// @dev If it is an active member, can not join again
    function testJoinModule_activeMembersShouldNotJoinAgain() public {
        vm.prank(admin);
        joinModule.setKYCStatus(alice);

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.startPrank(alice);
        // Alice joins the pool
        joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        // And tries to join again but fails
        vm.expectRevert(TakasureErrors.TakasurePool__WrongMemberState.selector);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));
        vm.stopPrank();
    }

    /// @dev `setKYCStatus` must revert if the member is address zero
    function testJoinModule_setKYCStatusMustRevertIfMemberIsAddressZero() public {
        vm.prank(admin);

        vm.expectRevert(TakasureErrors.TakasurePool__ZeroAddress.selector);
        joinModule.setKYCStatus(address(0));
    }

    /// @dev `setKYCStatus` must revert if the member is already KYC verified
    function testJoinModule_setKYCStatusMustRevertIfMemberIsAlreadyKYCVerified() public {
        vm.startPrank(admin);
        joinModule.setKYCStatus(alice);

        // And tries to join again but fails
        vm.expectRevert(TakasureErrors.TakasurePool__MemberAlreadyKYCed.selector);
        joinModule.setKYCStatus(alice);

        vm.stopPrank();
    }

    /// @dev `recurringPayment` must revert if the member is invalid
    function testMembersModule_recurringPaymentMustRevertIfMemberIsInvalid() public {
        vm.prank(alice);
        vm.expectRevert(TakasureErrors.TakasurePool__WrongMemberState.selector);
        membersModule.recurringPayment();
    }

    /// @dev `recurringPayment` must revert if the date is invalid, a year has passed and the member has not paid
    function testMembersModule_recurringPaymentMustRevertIfDateIsInvalidNotPaidInTime() public {
        vm.prank(admin);
        joinModule.setKYCStatus(alice);

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.startPrank(alice);
        usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank;

        vm.warp(block.timestamp + 396 days);
        vm.roll(block.number + 1);

        vm.startPrank(alice);
        vm.expectRevert(TakasureErrors.TakasurePool__InvalidDate.selector);
        membersModule.recurringPayment();
        vm.stopPrank;
    }

    /// @dev `recurringPayment` must revert if the date is invalid, the membership expired
    function testMembersModule_recurringPaymentMustRevertIfDateIsInvalidMembershipExpired() public {
        vm.prank(admin);
        joinModule.setKYCStatus(alice);

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.startPrank(alice);
        usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank;

        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + YEAR);
            vm.roll(block.number + 1);

            vm.startPrank(alice);
            membersModule.recurringPayment();
            vm.stopPrank;
        }

        vm.warp(block.timestamp + YEAR);
        vm.roll(block.number + 1);

        vm.startPrank(alice);
        vm.expectRevert(TakasureErrors.TakasurePool__InvalidDate.selector);
        membersModule.recurringPayment();
    }

    /// @dev can not refund someone already KYC verified
    function testJoinModule_refundRevertIfMemberIsKyc() public {
        vm.prank(admin);
        joinModule.setKYCStatus(alice);

        vm.prank(alice);
        vm.expectRevert(TakasureErrors.TakasurePool__MemberAlreadyKYCed.selector);
        joinModule.refund();
    }

    /// @dev can not refund someone already refunded
    function testJoinModule_refundRevertIfMemberAlreadyRefunded() public {
        vm.startPrank(alice);
        // Join and refund
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);

        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        joinModule.refund();

        // Try to refund again
        vm.expectRevert(TakasureErrors.TakasurePool__NothingToRefund.selector);
        joinModule.refund();
        vm.stopPrank();
    }

    /// @dev can not refund before 14 days
    function testJoinModule_refundRevertIfMemberRefundBefore14Days() public {
        // Join
        vm.startPrank(alice);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        // Try to refund
        vm.startPrank(alice);
        vm.expectRevert(TakasureErrors.TakasurePool__TooEarlytoRefund.selector);
        joinModule.refund();
        vm.stopPrank();
    }

    function test_onlyDaoAndTakadaoCanSetNewBenefitMultiplier() public {
        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setNewBenefitMultiplierConsumerAddress(alice);

        vm.prank(admin);
        vm.expectEmit(true, true, false, false, address(takasureReserve));
        emit TakasureEvents.OnBenefitMultiplierConsumerChanged(alice, address(bmConsumerMock));
        takasureReserve.setNewBenefitMultiplierConsumerAddress(alice);

        vm.prank(takadao);
        vm.expectEmit(true, true, false, false, address(takasureReserve));
        emit TakasureEvents.OnBenefitMultiplierConsumerChanged(address(bmConsumerMock), alice);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));
    }

    function testJoinModule_revertIfTryToJoinTwice() public {
        // First check kyc alice -> alice join -> alice join again must revert
        vm.prank(admin);
        joinModule.setKYCStatus(alice);

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.startPrank(alice);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.expectRevert(TakasureErrors.TakasurePool__WrongMemberState.selector);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        // Second check bob join -> kyc bob -> bob join again must revert
        vm.prank(bob);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);

        vm.prank(admin);
        joinModule.setKYCStatus(bob);

        vm.prank(bob);
        vm.expectRevert(TakasureErrors.TakasurePool__WrongMemberState.selector);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);

        // Third check charlie join -> charlie join again must revert
        vm.startPrank(charlie);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.expectRevert(TakasureErrors.TakasurePool__AlreadyJoinedPendingForKYC.selector);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        // Fourth check david join -> 14 days passes -> refund david -> kyc david -> david join -> david join again must revert
        vm.prank(david);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);

        vm.warp(block.timestamp + 15 days);
        vm.roll(block.number + 1);

        joinModule.refund(david);

        vm.prank(admin);
        joinModule.setKYCStatus(david);

        vm.startPrank(david);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.expectRevert(TakasureErrors.TakasurePool__WrongMemberState.selector);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        // Fifth check erin join -> 14 days passes -> refund erin -> erin join -> kyc erin -> erin join again must revert
        vm.prank(erin);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);

        vm.warp(block.timestamp + 15 days);
        vm.roll(block.number + 1);

        joinModule.refund(erin);

        vm.prank(erin);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);

        vm.prank(admin);
        joinModule.setKYCStatus(erin);

        vm.prank(erin);
        vm.expectRevert(TakasureErrors.TakasurePool__WrongMemberState.selector);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);

        // Sixth check frank join -> 14 days passes -> refund frank -> frank join -> frank join again must revert
        vm.prank(frank);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);

        vm.warp(block.timestamp + 15 days);
        vm.roll(block.number + 1);

        joinModule.refund(frank);

        vm.startPrank(frank);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.expectRevert(TakasureErrors.TakasurePool__AlreadyJoinedPendingForKYC.selector);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();
    }
}
