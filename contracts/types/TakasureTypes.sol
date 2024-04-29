// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

enum MemberState {
    Defaulted,
    Deceased,
    Active,
    Inactive
}

struct Member {
    uint256 memberId;
    uint256 benefitMultiplier;
    uint256 membershipDuration; // in years
    uint256 membershipStartTime; // in seconds
    uint256 netContribution; // in stablecoin currency in Wei
    address wallet;
    MemberState memberState;
    uint256 surplus; //Ratio of Net Contribution to the total net Contributions collected from all participants.
}

struct Fund {
    mapping(address member => Member) members;
    uint256 dynamicReserveRatio; // Default 40%
    uint256 benefitMultiplierAdjuster; // Default 1
    uint256 totalContributions;
    uint256 totalClaimReserve;
    uint256 totalFundReserve;
    uint256 wakalaFee; // Default 20%
}
