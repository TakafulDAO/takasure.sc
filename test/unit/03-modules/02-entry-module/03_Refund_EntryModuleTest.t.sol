// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";
import {UserRouter} from "contracts/router/UserRouter.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState, Reserve} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract Refund_EntryModuleTest is StdCheats, Test, SimulateDonResponse {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    EntryModule entryModule;
    MemberModule memberModule;
    UserRouter userRouter;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address admin;
    address kycService;
    address takadao;
    address entryModuleAddress;
    address memberModuleAddress;
    address userRouterAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public parent = makeAddr("parent");
    uint256 public constant USDC_INITIAL_AMOUNT = 150e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USD
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new TestDeployProtocol();
        (
            ,
            bmConsumerMock,
            takasureReserveProxy,
            ,
            entryModuleAddress,
            memberModuleAddress,
            ,
            userRouterAddress,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        entryModule = EntryModule(entryModuleAddress);
        memberModule = MemberModule(memberModuleAddress);
        userRouter = UserRouter(userRouterAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        kycService = config.kycProvider;
        takadao = config.takadaoOperator;

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(entryModuleAddress));

        vm.prank(takadao);
        entryModule.updateBmAddress();

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);
        deal(address(usdc), bob, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(memberModule), USDC_INITIAL_AMOUNT);

        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        _successResponse(address(bmConsumerMock));

        vm.startPrank(bob);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(memberModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
    }

    function testentryModule_refundContribution() public {
        Reserve memory reserve = takasureReserve.getReserveValues();
        uint8 serviceFee = reserve.serviceFee;
        uint256 expectedRefundAmount = (CONTRIBUTION_AMOUNT * (100 - serviceFee)) / 100;

        Member memory testMemberAfterKyc = takasureReserve.getMemberFromAddress(alice);

        uint256 contractBalanceBeforeRefund = usdc.balanceOf(address(entryModule));
        uint256 aliceBalanceBeforeRefund = usdc.balanceOf(alice);

        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        vm.startPrank(alice);
        vm.expectEmit(true, true, false, false, address(entryModule));
        emit TakasureEvents.OnRefund(testMemberAfterKyc.memberId, alice, expectedRefundAmount);
        entryModule.refund();
        vm.stopPrank();

        uint256 contractBalanceAfterRefund = usdc.balanceOf(address(entryModule));
        uint256 aliceBalanceAfterRefund = usdc.balanceOf(alice);

        assertEq(contractBalanceBeforeRefund - expectedRefundAmount, contractBalanceAfterRefund);
        assertEq(aliceBalanceBeforeRefund + expectedRefundAmount, aliceBalanceAfterRefund);

        // Cannot KYC someone who has been refunded until pays again
        vm.prank(kycService);
        vm.expectRevert(EntryModule.EntryModule__NoContribution.selector);
        entryModule.setKYCStatus(alice);

        vm.prank(alice);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);

        vm.prank(kycService);
        entryModule.setKYCStatus(alice);
    }

    function testEntryModule_sameIdIfJoinsAgainAfterRefund() public {
        Member memory aliceAfterFirstJoinBeforeRefund = takasureReserve.getMemberFromAddress(alice);
        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.startPrank(alice);
        entryModule.refund();
        vm.stopPrank();

        Member memory aliceAfterRefund = takasureReserve.getMemberFromAddress(alice);

        vm.startPrank(bob);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        vm.startPrank(alice);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        Member memory aliceAfterSecondJoin = takasureReserve.getMemberFromAddress(alice);

        assert(!aliceAfterFirstJoinBeforeRefund.isRefunded);
        assert(aliceAfterRefund.isRefunded);
        assertEq(aliceAfterFirstJoinBeforeRefund.memberId, aliceAfterRefund.memberId);
        assertEq(aliceAfterRefund.memberId, aliceAfterSecondJoin.memberId);
    }

    function testEntryModule_refundCalledByAnyone() public {
        Reserve memory reserve = takasureReserve.getReserveValues();
        uint8 serviceFee = reserve.serviceFee;
        uint256 expectedRefundAmount = (CONTRIBUTION_AMOUNT * (100 - serviceFee)) / 100;

        Member memory testMemberAfterKyc = takasureReserve.getMemberFromAddress(alice);

        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        vm.startPrank(bob);
        vm.expectEmit(true, true, false, false, address(entryModule));
        emit TakasureEvents.OnRefund(testMemberAfterKyc.memberId, alice, expectedRefundAmount);
        entryModule.refund(alice);
        vm.stopPrank();
    }
}
