// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {DeployConsumerMocks} from "test/utils/DeployConsumerMocks.s.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureErrors} from "contracts/libraries/TakasureErrors.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract Reverts_TakasurePoolTest is StdCheats, Test, SimulateDonResponse {
    TestDeployTakasure deployer;
    DeployConsumerMocks mockDeployer;
    TakasurePool takasurePool;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    address proxy;
    address contributionTokenAddress;
    address admin;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 150e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new TestDeployTakasure();
        (, proxy, contributionTokenAddress, helperConfig) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;

        mockDeployer = new DeployConsumerMocks();
        bmConsumerMock = mockDeployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        vm.prank(admin);
        takasurePool.setNewBenefitMultiplierConsumer(address(bmConsumerMock));

        vm.prank(msg.sender);
        bmConsumerMock.setNewRequester(address(takasurePool));
    }

    modifier tokensTo(address user) {
        deal(address(usdc), user, USDC_INITIAL_AMOUNT);
        vm.startPrank(user);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        vm.stopPrank;
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/
    /// @dev `setNewServiceFee` must revert if the caller is not the admin
    function testTakasurePool_setNewServiceFeeMustRevertIfTheCallerIsNotTheAdmin() public {
        uint8 newServiceFee = 50;
        vm.prank(alice);
        vm.expectRevert();
        takasurePool.setNewServiceFee(newServiceFee);
    }

    /// @dev `setNewServiceFee` must revert if it is higher than 35
    function testTakasurePool_setNewServiceFeeMustRevertIfHigherThan35() public {
        uint8 newServiceFee = 36;
        vm.prank(admin);
        vm.expectRevert(TakasureErrors.TakasurePool__WrongServiceFee.selector);
        takasurePool.setNewServiceFee(newServiceFee);
    }

    /// @dev `setNewMinimumThreshold` must revert if the caller is not the admin
    function testTakasurePool_setNewMinimumThresholdMustRevertIfTheCallerIsNotTheAdmin() public {
        uint8 newThreshold = 50;
        vm.prank(alice);
        vm.expectRevert();
        takasurePool.setNewMinimumThreshold(newThreshold);
    }

    /// @dev `setNewContributionToken` must revert if the caller is not the admin
    function testTakasurePool_setNewContributionTokenMustRevertIfTheCallerIsNotTheAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        takasurePool.setNewContributionToken(alice);
    }

    /// @dev `setNewContributionToken` must revert if the address is zero
    function testTakasurePool_setNewContributionTokenMustRevertIfAddressZero() public {
        vm.prank(admin);
        vm.expectRevert(TakasureErrors.TakasurePool__ZeroAddress.selector);
        takasurePool.setNewContributionToken(address(0));
    }

    /// @dev `setNewFeeClaimAddress` must revert if the caller is not the admin
    function testTakasurePool_setNewFeeClaimAddressMustRevertIfTheCallerIsNotTheAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        takasurePool.setNewFeeClaimAddress(alice);
    }

    /// @dev `setNewFeeClaimAddress` must revert if the address is zero
    function testTakasurePool_setNewFeeClaimAddressMustRevertIfAddressZero() public {
        vm.prank(admin);
        vm.expectRevert(TakasureErrors.TakasurePool__ZeroAddress.selector);
        takasurePool.setNewFeeClaimAddress(address(0));
    }

    /// @dev `setAllowCustomDuration` must revert if the caller is not the admin
    function testTakasurePool_setAllowCustomDurationMustRevertIfTheCallerIsNotTheAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        takasurePool.setAllowCustomDuration(true);
    }

    /// @dev `joinPool` must revert if the contribution is less than the minimum threshold
    function testTakasurePool_joinPoolMustRevertIfDepositLessThanMinimum() public {
        uint256 wrongContribution = CONTRIBUTION_AMOUNT / 2;
        vm.prank(alice);
        vm.expectRevert(TakasureErrors.TakasurePool__ContributionOutOfRange.selector);
        takasurePool.joinPool(wrongContribution, (5 * YEAR));
    }

    /// @dev If it is an active member, can not join again
    function testTakasurePool_activeMembersSholdNotJoinAgain() public tokensTo(alice) {
        vm.startPrank(admin);
        takasurePool.setKYCStatus(alice);
        vm.stopPrank();

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.startPrank(alice);
        // Alice joins the pool
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        // And tries to join again but fails
        vm.expectRevert(TakasureErrors.TakasurePool__MemberAlreadyExists.selector);
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));
        vm.stopPrank();
    }

    /// @dev `setKYCStatus` must revert if the member is address zero
    function testTakasurePool_setKYCStatusMustRevertIfMemberIsAddressZero() public {
        vm.prank(admin);

        vm.expectRevert(TakasureErrors.TakasurePool__ZeroAddress.selector);
        takasurePool.setKYCStatus(address(0));
    }

    /// @dev `setKYCStatus` must revert if the member is already KYC verified
    function testTakasurePool_setKYCStatusMustRevertIfMemberIsAlreadyKYCVerified() public {
        vm.startPrank(admin);
        takasurePool.setKYCStatus(alice);

        // And tries to join again but fails
        vm.expectRevert(TakasureErrors.TakasurePool__MemberAlreadyKYCed.selector);
        takasurePool.setKYCStatus(alice);

        vm.stopPrank();
    }

    /// @dev `recurringPayment` must revert if the member is invalid
    function testTakasurePool_recurringPaymentMustRevertIfMemberIsInvalid() public {
        vm.prank(alice);
        vm.expectRevert(TakasureErrors.TakasurePool__WrongMemberState.selector);
        takasurePool.recurringPayment();
    }

    /// @dev `recurringPayment` must revert if the date is invalid, the membership expired
    function testTakasurePool_recurringPaymentMustRevertIfDateIsInvalidMembershipExpired()
        public
        tokensTo(alice)
    {
        vm.startPrank(admin);
        takasurePool.setKYCStatus(alice);
        vm.stopPrank();

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.startPrank(alice);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank;

        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + YEAR);
            vm.roll(block.number + 1);

            vm.startPrank(alice);
            takasurePool.recurringPayment();
            vm.stopPrank;
        }

        vm.warp(block.timestamp + YEAR);
        vm.roll(block.number + 1);

        vm.startPrank(alice);
        vm.expectRevert(TakasureErrors.TakasurePool__InvalidDate.selector);
        takasurePool.recurringPayment();
    }

    /// @dev can not refund someone already KYC verified
    function testTakasurePool_refundRevertIfMemberIsKyc() public {
        vm.prank(admin);
        takasurePool.setKYCStatus(alice);

        vm.prank(alice);
        vm.expectRevert(TakasureErrors.TakasurePool__MemberAlreadyKYCed.selector);
        takasurePool.refund();
    }

    /// @dev can not refund someone already refunded
    function testTakasurePool_refundRevertIfMemberAlreadyRefunded() public tokensTo(alice) {
        vm.startPrank(alice);
        // Join and refund
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);

        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        takasurePool.refund();

        // Try to refund again
        vm.expectRevert(TakasureErrors.TakasurePool__NothingToRefund.selector);
        takasurePool.refund();
        vm.stopPrank();
    }

    /// @dev can not refund before 14 days
    function testTakasurePool_refundRevertIfMemberRefundBefore14Days() public tokensTo(alice) {
        // Join
        vm.startPrank(alice);
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        // Try to refund
        vm.startPrank(alice);
        vm.expectRevert(TakasureErrors.TakasurePool__TooEarlytoRefund.selector);
        takasurePool.refund();
        vm.stopPrank();
    }
}
