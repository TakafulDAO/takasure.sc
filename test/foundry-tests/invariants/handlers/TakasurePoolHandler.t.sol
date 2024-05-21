// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TakasurePool} from "../../../../contracts/takasure/TakasurePool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MemberState} from "../../../../contracts/types/TakasureTypes.sol";

contract TakasurePoolHandler is Test {
    TakasurePool takasurePool;
    ERC20 usdc;

    uint256 constant BENEFIT_MULTIPLIER = 1; // TODO: How much should be? it will be from oracle but should have valid values for tests
    uint256 constant MIN_DEPOSIT = 25e6; // 25 USDC
    uint256 constant MAX_DEPOSIT = type(uint32).max; // 4294.967295 USDC
    uint256 private constant DEFAULT_MEMBERSHIP_DURATION = 5 * (365 days); // 5 years

    constructor(TakasurePool _takasurePool) {
        takasurePool = _takasurePool;
        usdc = ERC20(address(takasurePool.getContributionTokenAddress()));
    }

    function joinPool(uint256 contributionAmount) public {
        vm.assume(msg.sender != address(0));
        vm.assume(msg.sender != address(takasurePool));

        MemberState currentMemberState = takasurePool.getMemberFromAddress(msg.sender).memberState;
        vm.assume(currentMemberState != MemberState.Active);

        contributionAmount = bound(contributionAmount, MIN_DEPOSIT, MAX_DEPOSIT);

        deal(address(usdc), msg.sender, contributionAmount);

        vm.startPrank(msg.sender);
        usdc.approve(address(takasurePool), contributionAmount);

        takasurePool.joinPool(BENEFIT_MULTIPLIER, contributionAmount, DEFAULT_MEMBERSHIP_DURATION);
        vm.stopPrank();
    }

    function moveOneDay() public {
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
    }
}
