// SPDX-License-Identifier: GNU GPLv3
import {IBenefitMultiplierConsumer} from "contracts/interfaces/IBenefitMultiplierConsumer.sol";

pragma solidity 0.8.28;

enum ModuleState {
    Disabled,
    Enabled,
    Paused,
    Deprecated
}

enum MemberState {
    Inactive,
    Active,
    Defaulted,
    Canceled,
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

struct CashFlowVars {
    uint256 dayDepositTimestamp;
    uint256 monthDepositTimestamp;
    uint16 monthReference;
    uint8 dayReference;
}

struct PrepaidMember {
    address member;
    uint256 contributionBeforeFee;
    uint256 contributionAfterFee;
    uint256 feeToOperator; // Fee after all the discounts and rewards
    uint256 discount;
    mapping(address child => uint256 rewards) parentRewardsByChild;
    mapping(uint256 layer => uint256 rewards) parentRewardsByLayer;
}

struct Member {
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
    address parent;
    MemberState memberState;
    uint256 memberSurplus; //Ratio of Net Contribution to the total net Contributions collected from all participants.
    bool isKYCVerified; // Can not be true if isRefunded is true
    bool isRefunded; // Can not be true if isKYCVerified is true
    uint256 lastEcr; // the last ECR calculated
    uint256 lastUcr; // the last UCR calculated
}

struct tDAO {
    mapping(address member => PrepaidMember) prepaidMembers;
    string name;
    bool preJoinEnabled;
    bool referralDiscount;
    address DAOAdmin; // The one that can modify the DAO settings
    address DAOAddress; // To be assigned when the tDAO is deployed
    uint256 launchDate; // In seconds. An estimated launch date of the DAO
    uint256 objectiveAmount; // In USDC, six decimals
    uint256 currentAmount; // In USDC, six decimals
    uint256 collectedFees; // Fees collected after deduct, discounts, referral reserve and repool amounts. In USDC, six decimals
    address rePoolAddress; // To be assigned when the tDAO is deployed
    uint256 toRepool; // In USDC, six decimals
    uint256 referralReserve; // In USDC, six decimals
    IBenefitMultiplierConsumer bmConsumer;
    address entryModule; // The module that will be used to enter the DAO
}

struct Reserve {
    uint8 serviceFee; // Default 22%, max 100%
    uint8 bmaFundReserveShare; // Default 70%
    uint8 fundMarketExpendsAddShare; // Default 20%
    uint8 riskMultiplier; // Default to 2%
    bool isOptimizerEnabled; // Default true
    bool allowCustomDuration; // Default false
    address daoToken;
    address contributionToken;
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
}
