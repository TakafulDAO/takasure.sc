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
    uint256 constant MIN_DISCOUNT = 5; // 5%
    string constant DAO_NAME = "The LifeDAO";
    address public couponRedeemer;

    constructor(ReferralGateway _referralGateway, address _couponRedeemer) {
        referralGateway = _referralGateway;
        usdc = ERC20(address(referralGateway.usdc()));
        couponRedeemer = _couponRedeemer;
    }

    function payContributionOnBehalfOf(
        uint256 contributionAmount,
        address parent,
        address newMember,
        uint256 couponAmount,
        bool isDonated
    ) public {
        // 1. User is not the zero address, the parent or the referral gateway address
        if (
            newMember == address(0) || newMember == parent || newMember == address(referralGateway)
        ) {
            skip = true;
            ghostFee = 0;
            ghostDiscount = 0;
        } else {
            // 2. User is not already a member
            (uint256 contributionBeforeFee, , , ) = referralGateway.getPrepaidMember(newMember);
            if (contributionBeforeFee != 0 || referralGateway.isMemberKYCed(newMember)) {
                skip = true;
                ghostFee = 0;
                ghostDiscount = 0;
            } else {
                // 3. Parent is valid
                if (parent != address(0) && !referralGateway.isMemberKYCed(parent)) {
                    skip = true;
                    ghostFee = 0;
                    ghostDiscount = 0;
                } else {
                    // 4. Contribution amount is within the limits
                    contributionAmount = bound(contributionAmount, MIN_DEPOSIT, MAX_DEPOSIT);
                    // 5. User has enough balance
                    deal(address(usdc), newMember, contributionAmount);
                    // 6. User approves the pool to spend the contribution amount and joins the pool
                    vm.prank(newMember);
                    usdc.approve(address(referralGateway), contributionAmount);

                    vm.prank(couponRedeemer);
                    (uint256 collectedFee, uint256 discount) = referralGateway
                        .payContributionOnBehalfOf(
                            contributionAmount,
                            parent,
                            newMember,
                            0,
                            isDonated
                        );

                    skip = false;
                    ghostFee = collectedFee;
                    ghostDiscount = discount;
                }
            }
            if (!skip) {
                (contributionBeforeFee, , , ) = referralGateway.getPrepaidMember(newMember);

                uint256 realContribution;

                if (isDonated) {
                    realContribution = MIN_DEPOSIT;
                } else {
                    realContribution = (contributionAmount / 1e4) * 1e4;
                }

                assert(ghostFee <= (realContribution * MAX_FEE) / 100);
                assert(ghostFee >= (realContribution * MIN_FEE) / 100000);
                assert(ghostDiscount <= (realContribution * MAX_DISCOUNT) / 100);
                assert(ghostDiscount >= (realContribution * MIN_DISCOUNT) / 100);
                assertEq(contributionBeforeFee, realContribution);
            }
        }
        totalFees += ghostFee;
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
