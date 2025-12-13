// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

/*//////////////////////////////////////////////////////////////
                                MODULES
//////////////////////////////////////////////////////////////*/

// Possible states a module can be in
enum ModuleState {
    Unset, // Default state
    Disabled, // It will disable selected functionalities
    Enabled, // Everything is enabled
    Paused, // All the functionalities are temporarily paused
    Deprecated // The module is deprecated, and no new interactions are allowed. This state cannot be changed
}

/*//////////////////////////////////////////////////////////////
                               ADDRESSES
//////////////////////////////////////////////////////////////*/

// Types of addresses in the protocol
enum ProtocolAddressType {
    Admin, // Admin EOAs or multisigs
    Benefit, // Special type of module that manages benefits (e.g., life, farewell)
    Module, // Modules that are part of the protocol
    Protocol // Core protocol contracts
}

// Struct to represent an address in the protocol
struct ProtocolAddress {
    bytes32 name; // Name of the address, e.g., "FEE_CLAIM_ADDRESS", "TAKASURE_RESERVE", "KYC_MODULE"
    address addr;
    ProtocolAddressType addressType;
}

/*//////////////////////////////////////////////////////////////
                                 ROLES
//////////////////////////////////////////////////////////////*/

// The ProposedRoleHolder struct is used to propose a new role holder, it contains
// the proposed holder address and the proposal time. The proposal time is used to
// ensure that the proposal is valid for a certain period of time.
struct ProposedRoleHolder {
    address proposedHolder;
    uint256 proposalTime;
}

/*//////////////////////////////////////////////////////////////
                                MEMBERS
//////////////////////////////////////////////////////////////*/

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

/*//////////////////////////////////////////////////////////////
                             MEMBERS STATES
//////////////////////////////////////////////////////////////*/

enum AssociationMemberState {
    Inactive, // Default state. The member has not been activated yet
    Active, // The member has paid the association membership and performed KYC
    PendingCancelation, // The member has requested to cancel the association membership
    Canceled // The member has canceled the association membership
}

enum BenefitMemberState {
    Inactive, // Default state. The member has not paid any benefit yet. From Inactive can only go to Active
    Active, // The member has paid the benefit contribution. From Active can change to: Defaulted, Canceled, Deceased
    PendingCancelation, // The member has requested to cancel their benefit membership. From PendingCancelation can change to: Active, Canceled
    Canceled, // The member has canceled their benefit membership. From Canceled can change to: Active
    Deceased // The member is deceased. This state is final and cannot be changed
}

/*//////////////////////////////////////////////////////////////
                                RESERVE
//////////////////////////////////////////////////////////////*/

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

/*//////////////////////////////////////////////////////////////
                                  CASH
//////////////////////////////////////////////////////////////*/

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

struct StrategyConfig {
    address asset; // USDC
    address vault;
    address keeper;
    address pool; // e.g. Uniswap v3/v4 pool
    uint256 maxTVL;
    bool paused;
    // optional: strategy type enum, fee params, slippage limits, etc.
}
