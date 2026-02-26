// SPDX-License-Identifier: GNU GPLv3

import {AssociationMemberState, BenefitMemberState} from "contracts/types/States.sol";

pragma solidity 0.8.28;

// Prepayer. From here it will became a member of the association
struct PrepaidMember {
    address member;
    uint256 contributionBeforeFee;
    uint256 contributionAfterFee;
    uint256 feeToOperator; // Fee after all the discounts and rewards
    uint256 discount;
    mapping(address child => uint256 rewards) parentRewardsByChild;
    mapping(uint256 layer => uint256 rewards) parentRewardsByLayer;
}

// Every protocol member is an AssociationMember, it could be prepaid or
// not if the protocol is already deployed
struct AssociationMember {
    uint256 memberId;
    uint256 planPrice; // Corresponds to the contribution plan selected in six decimals
    uint256 discount;
    uint256 couponAmountRedeemed; // in stablecoin currency, six decimals
    uint256 associateStartTime; // in seconds
    uint256 latestPayment; // in seconds, only the date for the latest association payment
    address wallet;
    address parent;
    AssociationMemberState memberState;
    bool isRefunded; // Can not be true if isKYCVerified is true
    address[] benefits; // List of benefit memberships
    address[] childs; // List of direct referrals
}

// Only those AssociationMembers that have paid some benefit can be BenefitMembers
struct BenefitMember {
    uint256 memberId;
    uint256 benefitMultiplier;
    uint256 membershipDuration; // in years
    uint256 membershipStartTime; // in seconds
    uint256 lastPaidYearStartDate; // in seconds
    uint256 contribution; // Six decimals
    uint256 discount;
    uint256 claimAddAmount; // amount deposited in the claim reserve, six decimals, and without fees
    uint256 totalContributions; // in stablecoin currency. Six decimals. This is the total contribution made by the member
    uint256 totalServiceFee; // in stablecoin currency six decimals
    uint256 creditsBalance; // 18 decimals
    address wallet;
    address parent;
    BenefitMemberState memberState;
    uint256 memberSurplus; //Ratio of Net Contribution to the total net Contributions collected from all participants.
    uint256 lastEcr; // the last ECR calculated
    uint256 lastUcr; // the last UCR calculated
}

