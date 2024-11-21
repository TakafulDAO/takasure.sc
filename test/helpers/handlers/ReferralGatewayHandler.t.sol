// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ReferralGatewayHandler is Test {
    ReferralGateway referralGateway;
    ERC20 usdc;

    bool public skip;
    uint256 public ghostFee;
    uint256 public ghostDiscount;

    uint256 public totalFees;

    uint256 constant MIN_DEPOSIT = 25e6; // 25 USDC
    uint256 constant MAX_DEPOSIT = 250e6; // 250 USDC

    uint256 public constant MAX_FEE = 27; // 27%
    uint256 public constant MIN_FEE = 4475; // 4.475%
    uint256 constant MAX_DISCOUNT = 15; // 15%
    uint256 constant MIN_DISCOUNT = 10; // 10%

    string constant DAO_NAME = "The LifeDAO";

    constructor(ReferralGateway _referralGateway) {
        referralGateway = _referralGateway;
        usdc = ERC20(address(referralGateway.usdc()));
    }

    function payContribution(uint256 contributionAmount, address newMember, address parent) public {
        // 1. User is not the zero address, the parent or the referral gateway address
        if (
            newMember == address(0) || newMember == parent || newMember == address(referralGateway)
        ) {
            skip = true;
            ghostFee = 0;
            ghostDiscount = 0;
        } else {
            // 2. User is not already a member
            (uint256 contributionBeforeFee, , , ) = referralGateway.getPrepaidMember(
                newMember,
                DAO_NAME
            );
            if (contributionBeforeFee != 0 || referralGateway.isMemberKYCed(newMember)) {
                skip = true;
                ghostFee = 0;
                ghostDiscount = 0;
            } else {
                // 3. Contribution amount is within the limits
                contributionAmount = bound(contributionAmount, MIN_DEPOSIT, MAX_DEPOSIT);
                // 4. User has enough balance
                deal(address(usdc), newMember, contributionAmount);
                // 5. User approves the pool to spend the contribution amount and joins the pool
                vm.startPrank(newMember);
                usdc.approve(address(referralGateway), contributionAmount);
                (uint256 collectedFee, uint256 discount) = referralGateway.payContribution(
                    contributionAmount,
                    DAO_NAME,
                    parent
                );
                vm.stopPrank();
                skip = false;
                ghostFee = collectedFee;
                ghostDiscount = discount;
            }
        }
        if (!skip) {
            assert(ghostFee <= (contributionAmount * MAX_FEE) / 100);
            assert(ghostFee >= (contributionAmount * MIN_FEE) / 100000);
            assert(ghostDiscount <= (contributionAmount * MAX_DISCOUNT) / 100);
            assert(ghostDiscount >= (contributionAmount * MIN_DISCOUNT) / 100);
        }
        totalFees += ghostFee;
    }
}
