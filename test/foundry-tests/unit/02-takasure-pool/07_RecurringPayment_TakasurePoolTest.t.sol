// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "../../../../scripts/foundry-deploy/DeployTokenAndPool.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "../../../../contracts/takasure/TakasurePool.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState} from "../../../../contracts/types/TakasureTypes.sol";
import {IUSDC} from "../../../../contracts/mocks/IUSDCmock.sol";

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

    event OnRecurringPayment(
        address indexed member,
        uint256 indexed updatedYearsCovered,
        uint256 indexed updatedContribution,
        uint256 updatedTotalWakalaFee
    );

    function setUp() public {
        deployer = new DeployTokenAndPool();
        (, proxy, , contributionTokenAddress, ) = deployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank;

        vm.startPrank(takasurePool.owner());
        takasurePool.setKYCStatus(alice);
        vm.stopPrank;
    }

    function testTakasurePool_recurringPaymentThrough5Years() public {
        uint256 expectedWakalaIncrease = (CONTRIBUTION_AMOUNT * 20) / 100;

        for (uint256 i = 0; i < 5; i++) {
            Member memory testMember = takasurePool.getMemberFromAddress(alice);

            uint256 yearBeforePayment = testMember.yearsCovered;
            uint256 contributionBeforePayment = testMember.contribution;
            uint256 totalWakalaFeeBeforePayment = testMember.totalWakalaFee;

            console2.log("Year", i);
            console2.log("Contribution: ", contributionBeforePayment);
            console2.log("Total Wakala Fee: ", totalWakalaFeeBeforePayment);
            console2.log("====================================");

            vm.warp(block.timestamp + YEAR);
            vm.roll(block.number + 1);

            vm.startPrank(alice);
            vm.expectEmit(true, true, true, true, address(takasurePool));
            emit OnRecurringPayment(
                alice,
                yearBeforePayment + 1,
                contributionBeforePayment + CONTRIBUTION_AMOUNT,
                totalWakalaFeeBeforePayment + expectedWakalaIncrease
            );
            takasurePool.recurringPayment(CONTRIBUTION_AMOUNT);
            vm.stopPrank;

            testMember = takasurePool.getMemberFromAddress(alice);

            uint256 yearAfterPayment = testMember.yearsCovered;
            uint256 contributionAfterPayment = testMember.contribution;
            uint256 totalWakalaFeeAfterPayment = testMember.totalWakalaFee;

            assert(yearAfterPayment == yearBeforePayment + 1);
            assert(contributionAfterPayment == contributionBeforePayment + CONTRIBUTION_AMOUNT);
            assert(
                totalWakalaFeeAfterPayment == totalWakalaFeeBeforePayment + expectedWakalaIncrease
            );
        }

        // Member memory testMember = takasurePool.getMemberFromAddress(alice);

        // uint256 year0 = testMember.yearsCovered;
        // uint256 contribution0 = testMember.contribution;
        // uint256 totalWakalaFee0 = testMember.totalWakalaFee;

        // console2.log("Year 0: ", year0);
        // console2.log("Contribution year 0: ", contribution0);
        // console2.log("Total Wakala Fee year 0: ", totalWakalaFee0);
        // console2.log("====================================");

        // First year have passed
        // vm.warp(block.timestamp + YEAR);
        // vm.roll(block.number + 1);

        // vm.startPrank(alice);
        // vm.expectEmit(true, true, true, true, address(takasurePool));
        // emit OnRecurringPayment(
        //     alice,
        //     year0 + 1,
        //     contribution0 + CONTRIBUTION_AMOUNT,
        //     totalWakalaFee0 + expectedWakalaIncrease
        // );
        // takasurePool.recurringPayment(CONTRIBUTION_AMOUNT);
        // vm.stopPrank;

        // testMember = takasurePool.getMemberFromAddress(alice);

        // uint256 year1 = testMember.yearsCovered;
        // uint256 contribution1 = testMember.contribution;
        // uint256 totalWakalaFee1 = testMember.totalWakalaFee;

        // console2.log("Year 1: ", year1);
        // console2.log("Contribution year 1: ", contribution1);
        // console2.log("Total Wakala Fee year 1: ", totalWakalaFee1);
        // console2.log("====================================");

        // assert(year1 == year0 + 1);
        // assert(contribution1 == contribution0 + CONTRIBUTION_AMOUNT);
        // assert(totalWakalaFee1 == totalWakalaFee0 + expectedWakalaIncrease);

        // Second year have passed
        // vm.warp(block.timestamp + YEAR);
        // vm.roll(block.number + 1);

        // // Third year have passed
        // vm.warp(block.timestamp + YEAR);
        // vm.roll(block.number + 1);

        // // Fourth year have passed
        // vm.warp(block.timestamp + YEAR);
        // vm.roll(block.number + 1);

        // // Fifth year have passed
        // vm.warp(block.timestamp + YEAR);
        // vm.roll(block.number + 1);
    }
}
