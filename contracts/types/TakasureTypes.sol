// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.24;

// Todo: Discuss
// ? This ones are all? Do we need more?
enum MemberState {
    Defaulted,
    Deceased,
    Active,
    Inactive
}

struct Fund {
    mapping(address member => Member) members;
    uint256 dynamicReserveRatio;
    uint256 BMA;
    uint256 totalContributions;
    uint256 totalClaimReserve;
    uint256 totalFundReserve;
    uint256 wakalaFee;
}

struct Member {
    uint256 memberId; // ? uint256? bytes32?
    uint256 membershipDuration; // ? in seconds?
    uint256 membershipStartTime;
    uint256 netContribution; // ? in wei? or token?
    address wallet;
    // address beneficiary; // ???
    MemberState memberState;
    uint256 surplus; //Ratio of Net Contribution to the total net Contributions collected from all participants.
}
