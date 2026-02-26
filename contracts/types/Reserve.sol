// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

struct Reserve {
    uint8 serviceFee; // Default 27%, max 35%
    uint8 bmaFundReserveShare; // Default 70%
    uint8 fundMarketExpendsAddShare; // Default 20%
    uint8 riskMultiplier; // Default to 2%
    bool isOptimizerEnabled; // Default true
    bool allowCustomDuration; // Default false
    bool referralDiscount;
    address contributionToken;
    uint256 totalCredits; // Total credits issued to members, 18 decimals
    uint256 memberIdCounter;
    uint256 minimumThreshold; // Default 25 USDC, 6 decimals
    uint256 maximumThreshold; // Default 250 USDC, 6 decimals
    uint256 initialReserveRatio; // Default 40%
    uint256 dynamicReserveRatio;
    uint256 benefitMultiplierAdjuster; // Default 100%
    uint256 totalContributions; // Default 0
    uint256 totalClaimReserve; // Default 0
    uint256 totalFundReserve; // Default 0
    uint256 totalFundCost; // Default 0
    uint256 totalFundRevenues; // Default 0
    uint256 proFormaFundReserve; // Used to update the dynamic reserve ratio
    uint256 proFormaClaimReserve;
    uint256 lossRatio; // Default 0
    uint256 lossRatioThreshold; // Default 80%
    uint256 ECRes; // Default 0
    uint256 UCRes; // Default 0
    uint256 surplus; // Default 0
    uint256 referralReserve; // In USDC, six decimals
}
