// SPDX-License-Identifier: GPL-3.0

/**
 * @title Events
 * @author  Maikel Ordaz
 * @notice  This library is used to store the events of the Takasure protocol
 */
pragma solidity 0.8.25;

library TakasureEvents {
    event OnMemberCreated(
        uint256 indexed memberId,
        address indexed member,
        uint256 indexed benefitMultiplier,
        uint256 contributionBeforeFee,
        uint256 serviceFee,
        uint256 membershipDuration,
        uint256 membershipStartTime
    ); // Emited when a new member is created
    event OnMemberUpdated(
        uint256 indexed memberId,
        address indexed member,
        uint256 indexed benefitMultiplier,
        uint256 contributionBeforeFee,
        uint256 serviceFee,
        uint256 membershipDuration,
        uint256 membershipStartTime
    ); // Emited when a member is updated. This is used when a member first KYCed and then paid the contribution
    event OnMemberJoined(uint256 indexed memberId, address indexed member);
    event OnMemberKycVerified(uint256 indexed memberId, address indexed member);
    event OnRecurringPayment(
        address member,
        uint256 indexed memberId,
        uint256 indexed updatedYearsCovered,
        uint256 indexed updatedContribution,
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
        address contributionToken,
        address daoToken
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
    event OnBenefitMultiplierConsumerChanged(
        address indexed newBenefitMultiplierConsumer,
        address indexed oldBenefitMultiplierConsumer
    );
    event OnNewMarketExpendsFundReserveAddShare(
        uint8 indexed newMarketExpendsFundReserveAddShare,
        uint8 indexed oldMarketExpendsFundReserveAddShare
    );
}
