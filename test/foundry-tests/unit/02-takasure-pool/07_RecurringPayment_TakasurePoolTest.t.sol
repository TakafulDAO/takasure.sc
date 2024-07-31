// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "scripts/foundry-deploy/DeployTokenAndPool.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "src/takasure/TakasurePool.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState} from "src/types/TakasureTypes.sol";
import {IUSDC} from "src/mocks/IUSDCmock.sol";
import {TakasureEvents} from "src/libraries/TakasureEvents.sol";

contract RecurringPayment_TakasurePoolTest is StdCheats, Test {
    DeployTokenAndPool deployer;
    TakasurePool takasurePool;
    ERC1967Proxy proxy;
    address contributionTokenAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 150e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant BENEFIT_MULTIPLIER = 0;
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new DeployTokenAndPool();
        (, proxy, , , contributionTokenAddress, ) = deployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank;

        vm.startPrank(takasurePool.owner());
        takasurePool.setKYCStatus(alice);
        vm.stopPrank;
    }

    function testTakasurePool_recurringPaymentThrough5Years() public {
        uint256 expectedServiceIncrease = (CONTRIBUTION_AMOUNT * 20) / 100;

        for (uint256 i = 0; i < 5; i++) {
            Member memory testMember = takasurePool.getMemberFromAddress(alice);

            uint256 yearBeforePayment = testMember.yearsCovered;
            uint256 totalContributionBeforePayment = testMember.totalContributions;
            uint256 totalServiceFeeBeforePayment = testMember.totalServiceFee;

            console2.log("Years Covered: ", yearBeforePayment);
            console2.log("Total Contribution: ", totalContributionBeforePayment);
            console2.log("Total Service Fee: ", totalServiceFeeBeforePayment);
            console2.log("====================================");

            vm.warp(block.timestamp + YEAR);
            vm.roll(block.number + 1);

            vm.startPrank(alice);
            vm.expectEmit(true, true, true, true, address(takasurePool));
            emit TakasureEvents.OnRecurringPayment(
                alice,
                testMember.memberId,
                yearBeforePayment + 1,
                totalContributionBeforePayment + CONTRIBUTION_AMOUNT,
                totalServiceFeeBeforePayment + expectedServiceIncrease
            );
            takasurePool.recurringPayment();
            vm.stopPrank;

            testMember = takasurePool.getMemberFromAddress(alice);

            uint256 yearAfterPayment = testMember.yearsCovered;
            uint256 totalContributionAfterPayment = testMember.totalContributions;
            uint256 totalServiceFeeAfterPayment = testMember.totalServiceFee;

            assert(yearAfterPayment == yearBeforePayment + 1);
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
