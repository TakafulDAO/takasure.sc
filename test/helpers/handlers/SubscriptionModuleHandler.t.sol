// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {AssociationMember} from "contracts/types/TakasureTypes.sol";

contract SubscriptionModuleHandler is Test {
    SubscriptionModule public subscriptionModule;
    IUSDC public token;
    address public operator;
    address[] public users;

    uint256 public totalSubscriptions;
    uint256 public totalRefunds;

    constructor(SubscriptionModule _subscriptionModule, IUSDC _token, address _operator) {
        subscriptionModule = _subscriptionModule;
        token = _token;
        operator = _operator;

        // Create 5 mock users with unique addresses and balances
        for (uint256 i = 0; i < 5; i++) {
            address user = makeAddr(string.concat("user_", vm.toString(i)));
            users.push(user);
            deal(address(token), user, 1_000_000e6); // 1M USDC with 6 decimals
        }
    }

    function paySubscription(uint256 userIndex, uint256 couponFlag) public {
        address user = users[userIndex % users.length];
        bool useCoupon = (couponFlag % 2 == 1);
        uint256 couponAmount = useCoupon ? 25e6 : 0;

        vm.startPrank(user);
        token.approve(address(subscriptionModule), 25e6);
        try
            subscriptionModule.paySubscriptionOnBehalfOf(
                user,
                address(0),
                couponAmount,
                block.timestamp
            )
        {
            totalSubscriptions++;
        } catch {}
        vm.stopPrank();
    }

    function refund(uint256 userIndex) public {
        // Advance time to allow refunds (30-day requirement)
        vm.warp(block.timestamp + 31 days);

        address user = users[userIndex % users.length];
        vm.prank(operator);
        try subscriptionModule.refund(user) {
            totalRefunds++;
        } catch {}
    }

    function usersLength() public view returns (uint256) {
        return users.length;
    }

    function usersAt(uint256 index) public view returns (address) {
        return users[index];
    }

    function countActiveMembers() public view returns (uint256 count) {
        for (uint256 i = 0; i < users.length; i++) {
            AssociationMember memory member = subscriptionModule.getAssociationMember(users[i]);
            if (!member.isRefunded && member.wallet != address(0)) count++;
        }
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
