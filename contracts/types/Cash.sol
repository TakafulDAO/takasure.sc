// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

enum CostTypes {
    Marketing,
    Claim,
    Surplus,
    CatFees,
    CastRepayment // Risk payment
}

enum RevenueType {
    Contribution,
    ContributionDonation,
    InvestmentReturn,
    CatDonation,
    CatLoan
}

struct CashFlowVars {
    uint256 dayDepositTimestamp;
    uint256 monthDepositTimestamp;
    uint16 monthReference;
    uint8 dayReference;
}

enum FeeType {
    MANAGEMENT,
    PERFORMANCE
}
