// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasureReserve} from "test/utils/TestDeployTakasureReserve.s.sol";
import {DeployConsumerMocks} from "test/utils/DeployConsumerMocks.s.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/takasure/core/TakasureReserve.sol";
import {JoinModule} from "contracts/takasure/modules/JoinModule.sol";
import {MembersModule} from "contracts/takasure/modules/MembersModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState, Reserve} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract Refund_TakasureProtocolTest is StdCheats, Test, SimulateDonResponse {
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
    uint256 public constant USDC_INITIAL_AMOUNT = 150e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USD
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

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(msg.sender);
        bmConsumerMock.setNewRequester(address(joinModuleAddress));

        vm.prank(takadao);
        joinModule.updateBmAddress();

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);
        deal(address(usdc), bob, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(membersModule), USDC_INITIAL_AMOUNT);

        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank;

        vm.startPrank(bob);
        usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(membersModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank;
    }

    function testJoinModule_refundContribution() public {
        Reserve memory reserve = takasureReserve.getReserveValues();
        uint8 serviceFee = reserve.serviceFee;
        uint256 expectedRefundAmount = (CONTRIBUTION_AMOUNT * (100 - serviceFee)) / 100;

        Member memory testMemberAfterKyc = takasureReserve.getMemberFromAddress(alice);

        uint256 contractBalanceBeforeRefund = usdc.balanceOf(address(joinModule));
        uint256 aliceBalanceBeforeRefund = usdc.balanceOf(alice);

        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        vm.startPrank(alice);
        vm.expectEmit(true, true, false, false, address(joinModule));
        emit TakasureEvents.OnRefund(testMemberAfterKyc.memberId, alice, expectedRefundAmount);
        joinModule.refund();
        vm.stopPrank();

        uint256 contractBalanceAfterRefund = usdc.balanceOf(address(joinModule));
        uint256 aliceBalanceAfterRefund = usdc.balanceOf(alice);

        assertEq(contractBalanceBeforeRefund - expectedRefundAmount, contractBalanceAfterRefund);
        assertEq(aliceBalanceBeforeRefund + expectedRefundAmount, aliceBalanceAfterRefund);
    }

    function testJoinModule_sameIdIfJoinsAgainAfterRefund() public {
        Member memory aliceAfterFirstJoinBeforeRefund = takasureReserve.getMemberFromAddress(alice);
        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.startPrank(alice);
        joinModule.refund();
        vm.stopPrank();

        Member memory aliceAfterRefund = takasureReserve.getMemberFromAddress(alice);

        vm.startPrank(bob);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        vm.startPrank(alice);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        Member memory aliceAfterSecondJoin = takasureReserve.getMemberFromAddress(alice);

        assert(!aliceAfterFirstJoinBeforeRefund.isRefunded);
        assert(aliceAfterRefund.isRefunded);
        assertEq(aliceAfterFirstJoinBeforeRefund.memberId, aliceAfterRefund.memberId);
        assertEq(aliceAfterRefund.memberId, aliceAfterSecondJoin.memberId);
    }

    function testJoinModule_refundCalledByAnyone() public {
        Reserve memory reserve = takasureReserve.getReserveValues();
        uint8 serviceFee = reserve.serviceFee;
        uint256 expectedRefundAmount = (CONTRIBUTION_AMOUNT * (100 - serviceFee)) / 100;

        Member memory testMemberAfterKyc = takasureReserve.getMemberFromAddress(alice);

        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        vm.startPrank(bob);
        vm.expectEmit(true, true, false, false, address(joinModule));
        emit TakasureEvents.OnRefund(testMemberAfterKyc.memberId, alice, expectedRefundAmount);
        joinModule.refund(alice);
        vm.stopPrank();
    }
}
