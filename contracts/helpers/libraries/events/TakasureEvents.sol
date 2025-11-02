// SPDX-License-Identifier: GNU GPLv3

/**
 * @title Events
 * @author  Maikel Ordaz
 * @notice  This library is used to store the events of the Takasure protocol
 */
import {RevenueType} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;

library TakasureEvents {
    event OnMemberCreated(
        uint256 indexed memberId,
        address indexed member,
        uint256 contributionBeforeFee,
        uint256 serviceFee,
        uint256 membershipDuration,
        uint256 membershipStartTime,
        bool isKycVerified
    ); // Emited when a new member is created
    event OnMemberJoined(uint256 indexed memberId, address indexed member);
    event OnMemberKycVerified(uint256 indexed memberId, address indexed member);
    event OnRecurringAssociationPayment(address member, uint256 indexed memberId);
    event OnRecurringBenefitPayment(
        address member,
        uint256 indexed memberId,
        uint256 indexed lastPaidYearDate,
        uint256 indexed latestContribution,
        uint256 updatedTotalServiceFee
    );
    event OnServiceFeeChanged(uint8 indexed newServiceFee);
    event OnInitialReserveValues(
        uint256 indexed initialReserveRatio,
        uint256 dynamicReserveRatio,
        uint256 indexed benefitMultiplierAdjuster,
        uint256 indexed serviceFee,
        uint256 bmaFundReserveShare,
        bool isOptimizerEnabled,
        address contributionToken
    );
    event OnNewProFormaValues(
        uint256 indexed proFormaFundReserve,
        uint256 indexed proFormaClaimReserve
    );
    event OnNewReserveValues(
        uint256 indexed totalContributions,
        uint256 indexed totalClaimReserve,
        uint256 indexed totalFundReserve,
        uint256 totalFundExpenditures
    );
    event OnNewDynamicReserveRatio(uint256 indexed dynamicReserveRatio);
    event OnNewBenefitMultiplierAdjuster(uint256 indexed benefitMultiplierAdjuster);
    event OnRefund(uint256 indexed memberId, address indexed member, uint256 indexed amount);
    event OnNewMinimumThreshold(uint256 indexed minimumThreshold);
    event OnNewMaximumThreshold(uint256 indexed maximumThreshold);
    event OnNewMarketExpendsFundReserveAddShare(
        uint8 indexed newMarketExpendsFundReserveAddShare,
        uint8 indexed oldMarketExpendsFundReserveAddShare
    );
    event OnNewLossRatio(uint256 indexed lossRatio);
    event OnExternalRevenue(
        uint256 indexed newRevenueAmount,
        uint256 indexed totalRevenues,
        RevenueType indexed revenueType
    );
    event OnFundSurplusUpdated(uint256 indexed surplus);
    event OnMemberSurplusUpdated(uint256 indexed memberId, uint256 indexed surplus);
    event OnAllowCustomDuration(bool allowCustomDuration);
    event OnAssociationMemberCanceled(uint256 indexed memberId, address indexed member);
    event OnBenefitMemberCanceled(
        uint256 indexed memberId,
        address indexed benefit,
        address indexed member
    );
    event OnParentRewarded(
        address indexed parent,
        uint256 indexed layer,
        address indexed child,
        uint256 reward
    );
    event OnNewRiskMultiplier(uint8 riskMultiplier);
    event OnParentRewardTransferFailed(
        address indexed parent,
        uint256 indexed layer,
        address indexed child,
        uint256 reward
    );
    event OnOperatorChanged(address indexed newOperator, address indexed oldOperator);
}
