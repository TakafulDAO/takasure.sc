// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {DeployConsumerMocks} from "test/utils/DeployConsumerMocks.s.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Reserve, Member, MemberState} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract Refund_TakasurePoolTest is StdCheats, Test, SimulateDonResponse {
    TestDeployTakasure deployer;
    DeployConsumerMocks mockDeployer;
    TakasurePool takasurePool;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConnsumerMock;
    address proxy;
    address contributionTokenAddress;
    address admin;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    uint256 public constant USDC_INITIAL_AMOUNT = 150e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant BENEFIT_MULTIPLIER = 0;
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new TestDeployTakasure();
        (, proxy, contributionTokenAddress, helperConfig) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;

        mockDeployer = new DeployConsumerMocks();
        bmConnsumerMock = mockDeployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        vm.prank(admin);
        takasurePool.setNewBenefitMultiplierConsumer(address(bmConnsumerMock));

        vm.prank(msg.sender);
        bmConnsumerMock.setNewRequester(address(takasurePool));

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);
        deal(address(usdc), bob, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank;

        vm.startPrank(bob);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        vm.stopPrank;
    }

    function testTakasurePool_refundContribution() public {
        Reserve memory reserve = takasurePool.getReserveValues();
        uint8 serviceFee = reserve.serviceFee;
        uint256 expectedRefundAmount = (CONTRIBUTION_AMOUNT * (100 - serviceFee)) / 100;

        Member memory testMemberAfterKyc = takasurePool.getMemberFromAddress(alice);

        uint256 contractBalanceBeforeRefund = usdc.balanceOf(address(takasurePool));
        uint256 aliceBalanceBeforeRefund = usdc.balanceOf(alice);

        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        vm.startPrank(alice);
        vm.expectEmit(true, true, false, false, address(takasurePool));
        emit TakasureEvents.OnRefund(testMemberAfterKyc.memberId, alice, expectedRefundAmount);
        takasurePool.refund();
        vm.stopPrank();

        uint256 contractBalanceAfterRefund = usdc.balanceOf(address(takasurePool));
        uint256 aliceBalanceAfterRefund = usdc.balanceOf(alice);

        assertEq(contractBalanceBeforeRefund - expectedRefundAmount, contractBalanceAfterRefund);
        assertEq(aliceBalanceBeforeRefund + expectedRefundAmount, aliceBalanceAfterRefund);
    }

    function testTakasurePool_sameIdIfJoinsAgainAfterRefund() public {
        Member memory aliceAfterFirstJoinBeforeRefund = takasurePool.getMemberFromAddress(alice);
        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        // We simulate a request before the KYC
        _successResponse(address(bmConnsumerMock));

        vm.startPrank(alice);
        takasurePool.refund();
        vm.stopPrank();

        Member memory aliceAfterRefund = takasurePool.getMemberFromAddress(alice);

        vm.startPrank(bob);
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        vm.startPrank(alice);
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        Member memory aliceAfterSecondJoin = takasurePool.getMemberFromAddress(alice);

        assert(!aliceAfterFirstJoinBeforeRefund.isRefunded);
        assert(aliceAfterRefund.isRefunded);
        assertEq(aliceAfterFirstJoinBeforeRefund.memberId, aliceAfterRefund.memberId);
        assertEq(aliceAfterRefund.memberId, aliceAfterSecondJoin.memberId);
    }

    function testTakasurePool_refundCalledByAnyone() public {
        Reserve memory reserve = takasurePool.getReserveValues();
        uint8 serviceFee = reserve.serviceFee;
        uint256 expectedRefundAmount = (CONTRIBUTION_AMOUNT * (100 - serviceFee)) / 100;

        Member memory testMemberAfterKyc = takasurePool.getMemberFromAddress(alice);

        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        vm.startPrank(bob);
        vm.expectEmit(true, true, false, false, address(takasurePool));
        emit TakasureEvents.OnRefund(testMemberAfterKyc.memberId, alice, expectedRefundAmount);
        takasurePool.refund(alice);
        vm.stopPrank();
    }
}
