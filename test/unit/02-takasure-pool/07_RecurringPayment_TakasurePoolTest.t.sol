// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract RecurringPayment_TakasurePoolTest is StdCheats, Test, SimulateDonResponse {
    TestDeployTakasure deployer;
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
    uint256 public constant BENEFIT_MULTIPLIER = 0;
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new TestDeployTakasure();
        (, bmConsumerMock, proxy, , contributionTokenAddress, , helperConfig) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;

        takasurePool = TakasurePool(proxy);
        usdc = IUSDC(contributionTokenAddress);

        vm.prank(admin);
        takasurePool.setNewBenefitMultiplierConsumer(address(bmConsumerMock));

        vm.prank(msg.sender);
        bmConsumerMock.setNewRequester(address(takasurePool));

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank;

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.startPrank(admin);
        takasurePool.setKYCStatus(alice);
        vm.stopPrank;
    }

    function testTakasurePool_recurringPaymentThrough5Years() public {
        uint256 expectedServiceIncrease = (CONTRIBUTION_AMOUNT * 22) / 100;

        for (uint256 i = 0; i < 5; i++) {
            Member memory testMember = takasurePool.getMemberFromAddress(alice);

            uint256 lastYearStartDateBefore = testMember.lastPaidYearStartDate;
            uint256 totalContributionBeforePayment = testMember.totalContributions;
            uint256 totalServiceFeeBeforePayment = testMember.totalServiceFee;

            vm.warp(block.timestamp + YEAR);
            vm.roll(block.number + 1);

            vm.startPrank(alice);
            vm.expectEmit(true, true, true, true, address(takasurePool));
            emit TakasureEvents.OnRecurringPayment(
                alice,
                testMember.memberId,
                lastYearStartDateBefore + 365 days,
                totalContributionBeforePayment + CONTRIBUTION_AMOUNT,
                totalServiceFeeBeforePayment + expectedServiceIncrease
            );
            takasurePool.recurringPayment();
            vm.stopPrank;

            testMember = takasurePool.getMemberFromAddress(alice);

            uint256 lastYearStartDateAfter = testMember.lastPaidYearStartDate;
            uint256 totalContributionAfterPayment = testMember.totalContributions;
            uint256 totalServiceFeeAfterPayment = testMember.totalServiceFee;

            assert(lastYearStartDateAfter == lastYearStartDateBefore + 365 days);
            assert(
                totalContributionAfterPayment ==
                    totalContributionBeforePayment + CONTRIBUTION_AMOUNT
            );
            assert(
                totalServiceFeeAfterPayment ==
                    totalServiceFeeBeforePayment + expectedServiceIncrease
            );
        }
    }
}
