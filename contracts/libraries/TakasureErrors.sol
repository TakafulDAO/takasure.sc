// SPDX-License-Identifier: GPL-3.0

/**
 * @title Errors
 * @author  Maikel Ordaz
 * @notice  This library is used to store the errors of the Takasure protocol
 */
pragma solidity 0.8.28;

library TakasureErrors {
    // Global Errors
    error TakasureProtocol__ZeroAddress();
    // Exclusive Takasurereserve Errors
    error TakasureReserve__OnlyDaoOrTakadao();
    error TakasureReserve__WrongServiceFee();
    error TakasureReserve__WrongFundMarketExpendsShare();
    // Modules Errors
    error Module__ContributionTransferFailed();
    error Module__FeeTransferFailed();
    error Module__MintFailed();
    error Module__WrongMemberState();
    // Exclusive JoinModule Errors
    error JoinModule__NoContribution();
    error JoinModule__ContributionOutOfRange();
    error JoinModule__AlreadyJoinedPendingForKYC();
    error JoinModule__BenefitMultiplierRequestFailed(bytes errorResponse);
    error JoinModule__MemberAlreadyKYCed();
    error JoinModule__NothingToRefund();
    error JoinModule__RefundFailed();
    error JoinModule__TooEarlytoRefund();
    // Exclusive MembersModule Errors
    error MembersModule__InvalidDate();
    // Exclusive RevenueModule Errors
    error RevenueModule__WrongRevenueType();
    error RevenueModule__RevenueTransferFailed();
}
