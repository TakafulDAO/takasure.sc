// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";
import {UserRouter} from "contracts/router/UserRouter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MemberState} from "contracts/types/TakasureTypes.sol";

contract TakasureProtocolHandler is Test {
    TakasureReserve takasureReserve;
    SubscriptionModule subscriptionModule;
    MemberModule memberModule;
    UserRouter userRouter;
    ERC20 usdc;
    address public parent = makeAddr("parent");

    uint256 constant MIN_DEPOSIT = 25e6; // 25 USDC
    uint256 constant MAX_DEPOSIT = 2025e5; // 202.50 USDC
    uint256 private constant DEFAULT_MEMBERSHIP_DURATION = 5 * (365 days); // 5 years

    constructor(
        TakasureReserve _takasureReserve,
        SubscriptionModule _subscriptionModule,
        MemberModule _memberModule,
        UserRouter _userRouter
    ) {
        takasureReserve = _takasureReserve;
        subscriptionModule = _subscriptionModule;
        memberModule = _memberModule;
        userRouter = _userRouter;
        usdc = ERC20(address(takasureReserve.getReserveValues().contributionToken));
    }

    function joinPool(uint256 contributionAmount) public {
        // 1. User is not the zero address or the contracts address
        vm.assume(msg.sender != address(0));
        vm.assume(msg.sender != address(takasureReserve));
        vm.assume(msg.sender != address(subscriptionModule));
        vm.assume(msg.sender != address(memberModule));

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
        usdc.approve(address(subscriptionModule), contributionAmount);

        userRouter.paySubscription(parent, contributionAmount, DEFAULT_MEMBERSHIP_DURATION);
        vm.stopPrank();
    }

    function moveTime(uint256 time) public {
        time = bound(time, 0, 7 days);
        vm.warp(block.timestamp + time);
        vm.roll(block.number + time);

        // console2.log("Date updated by", time / 1 days, "days");
        // console2.log("=====================================");
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
