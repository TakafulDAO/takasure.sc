// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {KYCModule} from "contracts/modules/KYCModule.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState, Reserve} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";

contract Refund_SubscriptionModuleTest is StdCheats, Test, SimulateDonResponse {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    SubscriptionModule subscriptionModule;
    KYCModule kycModule;
    MemberModule memberModule;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address admin;
    address kycService;
    address takadao;
    address subscriptionModuleAddress;
    address kycModuleAddress;
    address memberModuleAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    uint256 public constant CONTRIBUTION_AMOUNT = 250e6; // 250 USD
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new TestDeployProtocol();
        (
            ,
            bmConsumerMock,
            takasureReserveProxy,
            ,
            subscriptionModuleAddress,
            kycModuleAddress,
            memberModuleAddress,
            ,
            ,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        subscriptionModule = SubscriptionModule(subscriptionModuleAddress);
        kycModule = KYCModule(kycModuleAddress);
        memberModule = MemberModule(memberModuleAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        kycService = config.kycProvider;
        takadao = config.takadaoOperator;

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.startPrank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(subscriptionModuleAddress));
        bmConsumerMock.setNewRequester(address(kycModuleAddress));
        vm.stopPrank();

        vm.startPrank(takadao);
        subscriptionModule.updateBmAddress();
        kycModule.updateBmAddress();
        vm.stopPrank();

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, CONTRIBUTION_AMOUNT);
        deal(address(usdc), bob, CONTRIBUTION_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(subscriptionModule), CONTRIBUTION_AMOUNT);
        usdc.approve(address(memberModule), CONTRIBUTION_AMOUNT);

        subscriptionModule.paySubscription(alice, address(0), CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        _successResponse(address(bmConsumerMock));

        vm.startPrank(bob);
        usdc.approve(address(subscriptionModule), CONTRIBUTION_AMOUNT);
        usdc.approve(address(memberModule), CONTRIBUTION_AMOUNT);
        vm.stopPrank();
    }

    function testSubscriptionModule_refundContributionIfThereWhereNoParent() public {
        Member memory Alice = takasureReserve.getMemberFromAddress(alice);

        // contribution - discount - 27% fee
        // 250 - 0 - (250 * 27 / 100) = 250 - 0 - 67.5 = 182.5
        // Discount is 0 because Alice has no parent
        uint256 expectedRefundAmount = 1825e5;

        uint256 contractBalanceBeforeRefund = usdc.balanceOf(address(subscriptionModule));
        uint256 aliceBalanceBeforeRefund = usdc.balanceOf(alice);

        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        vm.prank(bob);
        vm.expectRevert(ModuleErrors.Module__NotAuthorizedCaller.selector);
        subscriptionModule.refund(alice);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false, address(subscriptionModule));
        emit TakasureEvents.OnRefund(Alice.memberId, alice, expectedRefundAmount);
        subscriptionModule.refund();

        uint256 contractBalanceAfterRefund = usdc.balanceOf(address(subscriptionModule));
        uint256 aliceBalanceAfterRefund = usdc.balanceOf(alice);

        assertEq(contractBalanceBeforeRefund - expectedRefundAmount, contractBalanceAfterRefund);
        assertEq(aliceBalanceBeforeRefund + expectedRefundAmount, aliceBalanceAfterRefund);

        // Cannot KYC someone who has been refunded until pays again
        vm.prank(kycService);
        vm.expectRevert(KYCModule.KYCModule__NoContribution.selector);
        kycModule.approveKYC(alice);

        vm.startPrank(alice);
        usdc.approve(address(subscriptionModule), expectedRefundAmount);
        subscriptionModule.paySubscription(alice, address(0), expectedRefundAmount, 5 * YEAR);
        vm.stopPrank();
    }

    function testSubscriptionModule_refundContributionIfThereIsParent() public {
        // First we need to KYC Alice so she can act as a parent
        vm.prank(kycService);
        kycModule.approveKYC(alice);

        vm.prank(bob);
        subscriptionModule.paySubscription(bob, alice, CONTRIBUTION_AMOUNT, 5 * YEAR);

        Member memory Bob = takasureReserve.getMemberFromAddress(bob);

        // contribution - discount - 27% fee
        // 250 - (250 * 5 / 100) - (250 * 27 / 100) = 250 - 12.5 - 67.5 = 170
        // The discount is 5% because Bob has Alice as parent
        uint256 expectedRefundAmount = 170e6;

        uint256 contractBalanceBeforeRefund = usdc.balanceOf(address(subscriptionModule));
        uint256 bobBalanceBeforeRefund = usdc.balanceOf(bob);

        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        vm.prank(bob);
        vm.expectEmit(true, true, false, false, address(subscriptionModule));
        emit TakasureEvents.OnRefund(Bob.memberId, bob, expectedRefundAmount);
        subscriptionModule.refund();

        uint256 contractBalanceAfterRefund = usdc.balanceOf(address(subscriptionModule));
        uint256 bobBalanceAfterRefund = usdc.balanceOf(bob);

        assertEq(contractBalanceBeforeRefund - expectedRefundAmount, contractBalanceAfterRefund);
        assertEq(bobBalanceBeforeRefund + expectedRefundAmount, bobBalanceAfterRefund);
    }

    function testSubscriptionModule_refundContributionIfThereIsParentButWithoutDiscount() public {
        // First set referral discount to false
        vm.prank(takadao);
        takasureReserve.setReferralDiscountState(false);

        // First we need to KYC Alice so she can act as a parent
        vm.prank(kycService);
        kycModule.approveKYC(alice);

        vm.prank(bob);
        subscriptionModule.paySubscription(bob, alice, CONTRIBUTION_AMOUNT, 5 * YEAR);

        Member memory Bob = takasureReserve.getMemberFromAddress(bob);

        // contribution - discount - 27% fee
        // 250 - 0 - (250 * 27 / 100) = 250 - 0 - 67.5 = 182.5
        // The discount is 0 because the discount is off
        uint256 expectedRefundAmount = 1825e5;

        uint256 contractBalanceBeforeRefund = usdc.balanceOf(address(subscriptionModule));
        uint256 bobBalanceBeforeRefund = usdc.balanceOf(bob);

        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        vm.prank(bob);
        vm.expectEmit(true, true, false, false, address(subscriptionModule));
        emit TakasureEvents.OnRefund(Bob.memberId, bob, expectedRefundAmount);
        subscriptionModule.refund();

        uint256 contractBalanceAfterRefund = usdc.balanceOf(address(subscriptionModule));
        uint256 bobBalanceAfterRefund = usdc.balanceOf(bob);

        assertEq(contractBalanceBeforeRefund - expectedRefundAmount, contractBalanceAfterRefund);
        assertEq(bobBalanceBeforeRefund + expectedRefundAmount, bobBalanceAfterRefund);
    }

    function testSubscriptionModule_refundContributionIfThereIsParentAndIsCouponUser() public {
        // Set the coupon pool and the coupon redeemer
        address couponPool = makeAddr("couponPool");
        address couponRedeemer = makeAddr("couponRedeemer");

        deal(address(usdc), couponPool, CONTRIBUTION_AMOUNT);

        vm.prank(couponPool);
        usdc.approve(address(subscriptionModule), CONTRIBUTION_AMOUNT);

        vm.startPrank(takadao);
        subscriptionModule.setCouponPoolAddress(couponPool);
        subscriptionModule.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        vm.stopPrank();

        // KYC Alice so she can act as a parent
        vm.prank(kycService);
        kycModule.approveKYC(alice);

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(
            bob,
            alice,
            CONTRIBUTION_AMOUNT,
            5 * YEAR,
            (CONTRIBUTION_AMOUNT / 2)
        );

        Member memory Bob = takasureReserve.getMemberFromAddress(bob);

        // contribution - discount - 27% fee
        // 250 - ((250 - 125) * 5 / 100) - (250 * 27 / 100) = 250 - (125 * 5 / 100) - 67.5
        // = 250 - 6.25 - 67.5 = 176.25
        // The discount is 5% because Bob has Alice as parent, but in this case the discount is applied
        // to the contribution amount minus the coupon amount, so it is the 5% of 125 USDC
        uint256 expectedRefundAmount = 17625e4;

        uint256 contractBalanceBeforeRefund = usdc.balanceOf(address(subscriptionModule));
        uint256 bobBalanceBeforeRefund = usdc.balanceOf(bob);
        uint256 couponPoolBalanceBeforeRefund = usdc.balanceOf(couponPool);

        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        vm.prank(bob);
        vm.expectEmit(true, true, false, false, address(subscriptionModule));
        emit TakasureEvents.OnRefund(Bob.memberId, bob, expectedRefundAmount);
        subscriptionModule.refund();

        uint256 contractBalanceAfterRefund = usdc.balanceOf(address(subscriptionModule));
        uint256 bobBalanceAfterRefund = usdc.balanceOf(bob);
        uint256 couponPoolBalanceAfterRefund = usdc.balanceOf(couponPool);

        assertEq(contractBalanceBeforeRefund - expectedRefundAmount, contractBalanceAfterRefund);
        // In this case, as Bob used a coupon, the refund amount is not transferred to Bob, but to the coupon pool
        assertEq(bobBalanceBeforeRefund, bobBalanceAfterRefund);
        assertEq(
            couponPoolBalanceBeforeRefund + expectedRefundAmount,
            couponPoolBalanceAfterRefund
        );
    }

    function testSubscriptionModule_sameIdIfJoinsAgainAfterRefund() public {
        Member memory aliceAfterFirstJoinBeforeRefund = takasureReserve.getMemberFromAddress(alice);
        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(alice);
        subscriptionModule.refund();

        Member memory aliceAfterRefund = takasureReserve.getMemberFromAddress(alice);

        vm.prank(bob);
        subscriptionModule.paySubscription(bob, address(0), CONTRIBUTION_AMOUNT, 5 * YEAR);

        vm.startPrank(alice);
        usdc.approve(address(subscriptionModule), 100e6);
        subscriptionModule.paySubscription(alice, address(0), 100e6, 5 * YEAR);
        vm.stopPrank();

        Member memory aliceAfterSecondJoin = takasureReserve.getMemberFromAddress(alice);

        assert(!aliceAfterFirstJoinBeforeRefund.isRefunded);
        assert(aliceAfterRefund.isRefunded);
        assertEq(aliceAfterFirstJoinBeforeRefund.memberId, aliceAfterRefund.memberId);
        assertEq(aliceAfterRefund.memberId, aliceAfterSecondJoin.memberId);
    }
}
