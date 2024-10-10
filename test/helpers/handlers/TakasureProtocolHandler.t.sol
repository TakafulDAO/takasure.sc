// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TakasureReserve} from "contracts/takasure/core/TakasureReserve.sol";
import {JoinModule} from "contracts/takasure/modules/JoinModule.sol";
import {MembersModule} from "contracts/takasure/modules/MembersModule.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MemberState} from "contracts/types/TakasureTypes.sol";

contract TakasureProtocolHandler is Test {
    TakasureReserve takasureReserve;
    JoinModule joinModule;
    MembersModule membersModule;
    ERC20 usdc;

    uint256 constant MIN_DEPOSIT = 25e6; // 25 USDC
    uint256 constant MAX_DEPOSIT = 2025e5; // 202.50 USDC
    uint256 private constant DEFAULT_MEMBERSHIP_DURATION = 5 * (365 days); // 5 years

    constructor(
        TakasureReserve _takasureReserve,
        JoinModule _joinModule,
        MembersModule _membersModule
    ) {
        takasureReserve = _takasureReserve;
        joinModule = _joinModule;
        membersModule = _membersModule;
        usdc = ERC20(address(takasureReserve.getReserveValues().contributionToken));
    }

    function joinPool(uint256 contributionAmount) public {
        // 1. User is not the zero address or the contracts address
        vm.assume(msg.sender != address(0));
        vm.assume(msg.sender != address(takasureReserve));
        vm.assume(msg.sender != address(joinModule));
        vm.assume(msg.sender != address(membersModule));

        // 2. User is not already a member
        MemberState currentMemberState = takasureReserve
            .getMemberFromAddress(msg.sender)
            .memberState;
        vm.assume(currentMemberState != MemberState.Active);

        // 3. Contribution amount is within the limits
        contributionAmount = bound(contributionAmount, MIN_DEPOSIT, MAX_DEPOSIT);

        // 4. User has enough balance
        deal(address(usdc), msg.sender, contributionAmount);

        // 5. User approves the pool to spend the contribution amount and joins the pool
        vm.startPrank(msg.sender);
        usdc.approve(address(joinModule), contributionAmount);

        joinModule.joinPool(contributionAmount, DEFAULT_MEMBERSHIP_DURATION);
        vm.stopPrank();
    }

    function moveTime(uint256 time) public {
        time = bound(time, 0, 7 days);
        vm.warp(block.timestamp + time);
        vm.roll(block.number + time);

        // console2.log("Date updated by", time / 1 days, "days");
        // console2.log("=====================================");
    }
}
