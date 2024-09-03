// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MemberState} from "contracts/types/TakasureTypes.sol";

contract TakasurePoolHandler is Test {
    TakasurePool takasurePool;
    ERC20 usdc;

    uint256 constant BENEFIT_MULTIPLIER = 1; // TODO: How much should be? it will be from oracle but should have valid values for tests
    uint256 constant MIN_DEPOSIT = 25e6; // 25 USDC
    uint256 constant MAX_DEPOSIT = 2025e5; // 202.50 USDC
    uint256 private constant DEFAULT_MEMBERSHIP_DURATION = 5 * (365 days); // 5 years

    constructor(TakasurePool _takasurePool) {
        takasurePool = _takasurePool;
        uint256 contributionTokenAddressSlot = 0;
        bytes32 contributionTokenAddressSlotBytes = vm.load(
            address(takasurePool),
            bytes32(uint256(contributionTokenAddressSlot))
        );

        address contributionTokenAddress = address(
            uint160(uint256(contributionTokenAddressSlotBytes))
        );
        usdc = ERC20(contributionTokenAddress);
    }

    function joinPool(uint256 contributionAmount) public {
        // 1. User is not the zero address or the pool address
        vm.assume(msg.sender != address(0));
        vm.assume(msg.sender != address(takasurePool));

        // 2. User is not already a member
        MemberState currentMemberState = takasurePool.getMemberFromAddress(msg.sender).memberState;
        vm.assume(currentMemberState != MemberState.Active);

        // 3. Contribution amount is within the limits
        contributionAmount = bound(contributionAmount, MIN_DEPOSIT, MAX_DEPOSIT);

        // 4. User has enough balance
        deal(address(usdc), msg.sender, contributionAmount);

        // 5. User approves the pool to spend the contribution amount and joins the pool
        vm.startPrank(msg.sender);
        usdc.approve(address(takasurePool), contributionAmount);

        takasurePool.joinPool(contributionAmount, DEFAULT_MEMBERSHIP_DURATION);
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
