// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

enum MemberState {
    Inactive,
    Active,
    Defaulted,
    Deceased
}

struct Member {
    uint256 memberId;
    uint256 benefitMultiplier;
    uint256 membershipDuration; // in years
    uint256 membershipStartTime; // in seconds
    uint256 lockedFunds; // in stablecoin currency in Wei
    uint256 contribution; // in stablecoin currency in Wei
    uint256 totalWakalaFee; // in stablecoin currency in Wei
    address wallet;
    MemberState memberState;
    uint256 surplus; //Ratio of Net Contribution to the total net Contributions collected from all participants.
    bool isKYCVerified;
}

struct Reserve {
    mapping(address member => Member) members;
    uint256 initialReserveRatio; // Default 40%
    uint256 dynamicReserveRatio; // Default 40%
    uint256 benefitMultiplierAdjuster; // Default 100%
    uint256 totalContributions; // Default 0
    uint256 totalClaimReserve; // Default 0
    uint256 totalFundReserve; // Default 0
    uint256 proFormaFundReserve; // Used to update the dynamic reserve ratio
    uint256 proFormaClaimReserve;
    uint256 lossRatio; // Default 0
    uint8 wakalaFee; // Default 20%, max 100%
    uint8 bmaFundReserveShare; // Default 70%
    bool isOptimizerEnabled; // Default false
}
