// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {PrejoinModule} from "contracts/modules/PrejoinModule.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PrejoinModuleHandler is Test {
    PrejoinModule prejoinModule;
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

    constructor(PrejoinModule _prejoinModule) {
        prejoinModule = _prejoinModule;
        usdc = ERC20(address(prejoinModule.usdc()));
    }

    function payContribution(uint256 contributionAmount, address newMember, address parent) public {
        // 1. User is not the zero address, the parent or the referral gateway address
        if (newMember == address(0) || newMember == parent || newMember == address(prejoinModule)) {
            skip = true;
            ghostFee = 0;
            ghostDiscount = 0;
        } else {
            // 2. User is not already a member
            (uint256 contributionBeforeFee, , , ) = prejoinModule.getPrepaidMember(newMember);
            if (contributionBeforeFee != 0 || prejoinModule.isMemberKYCed(newMember)) {
                skip = true;
                ghostFee = 0;
                ghostDiscount = 0;
            } else {
                // 3. Parent is valid
                if (parent != address(0) && !prejoinModule.isMemberKYCed(parent)) {
                    skip = true;
                    ghostFee = 0;
                    ghostDiscount = 0;
                } else {
                    // 4. Contribution amount is within the limits
                    contributionAmount = bound(contributionAmount, MIN_DEPOSIT, MAX_DEPOSIT);
                    // 5. User has enough balance
                    deal(address(usdc), newMember, contributionAmount);
                    // 6. User approves the pool to spend the contribution amount and joins the pool
                    vm.startPrank(newMember);
                    usdc.approve(address(prejoinModule), contributionAmount);
                    (uint256 collectedFee, uint256 discount) = prejoinModule.payContribution(
                        contributionAmount,
                        parent
                    );
                    vm.stopPrank();
                    skip = false;
                    ghostFee = collectedFee;
                    ghostDiscount = discount;
                }
            }
        }
        if (!skip) {
            uint256 normalizedContribution = (contributionAmount / 1e4) * 1e4;

            assert(ghostFee <= (normalizedContribution * MAX_FEE) / 100);
            assert(ghostFee >= (normalizedContribution * MIN_FEE) / 100000);
            assert(ghostDiscount <= (normalizedContribution * MAX_DISCOUNT) / 100);
            assert(ghostDiscount >= (normalizedContribution * MIN_DISCOUNT) / 100);
        }
        totalFees += ghostFee;
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
