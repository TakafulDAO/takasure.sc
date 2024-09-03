// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

enum MemberState {
    Inactive,
    Active,
    Defaulted,
    Deceased
}

enum CostTypes {
    Marketing,
    Claim,
    Surplus,
    CatFees,
    CastRepayment // Risk payment
}

enum RevenueType {
    Contribution,
    InvestmentReturn,
    CatDonation,
    CatLoan
}

struct Member {
    MemberState memberState;
    uint256 memberId;
    uint256 benefitMultiplier;
    uint256 membershipDuration; // in years
    uint256 membershipStartTime; // in seconds
    uint256 lastPaidYearStartDate; // in seconds
    uint256 contribution; // in stablecoin currency in Wei
    uint256 claimAddAmount; // amount deposited in the claim reserve, in stablecoin currency in Wei, and without fees
    uint256 totalContributions; // in stablecoin currency in Wei. This is the total contribution made by the member
    uint256 totalServiceFee; // in stablecoin currency in Wei
    uint256 creditTokensBalance; // 18 decimals
    address wallet;
    uint256 memberSurplus; //Ratio of Net Contribution to the total net Contributions collected from all participants.
    bool isKYCVerified; // Can not be true if isRefunded is true
    bool isRefunded; // Can not be true if isKYCVerified is true
    uint256 lastEcr; // the last ECR calculated
    uint256 lastUcr; // the last UCR calculated
}

struct Reserve {
    uint256 dynamicReserveRatio; // Default 40%
    uint256 benefitMultiplierAdjuster; // Default 100%
    uint256 totalContributions; // Default 0
    uint256 totalClaimReserve; // Default 0
    uint256 totalFundReserve; // Default 0
    uint256 totalFundCost; // Default 0
    uint256 totalFundRevenues; // Default 0
    uint256 proFormaFundReserve; // Used to update the dynamic reserve ratio
    uint256 proFormaClaimReserve;
    uint256 lossRatio; // Default 0
    uint8 serviceFee; // Default 22%, max 100%
    uint256 ECRes; // Default 0
    uint256 UCRes; // Default 0
    uint256 surplus; // Default 0
}
