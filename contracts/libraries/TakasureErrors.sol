// SPDX-License-Identifier: GPL-3.0

/**
 * @title Errors
 * @author  Maikel Ordaz
 * @notice  This library is used to store the errors of the Takasure protocol
 */
pragma solidity 0.8.25;

library TakasureErrors {
    error TakasurePool__MemberAlreadyExists();
    error TakasurePool__ZeroAddress();
    error TakasurePool__ContributionBelowMinimumThreshold();
    error TakasurePool__ContributionTransferFailed();
    error TakasurePool__FeeTransferFailed();
    error TakasurePool__MintFailed();
    error TakasurePool__WrongServiceFee();
    error TakasurePool__MemberAlreadyKYCed();
    error TakasurePool__WrongMemberState();
    error TakasurePool__InvalidDate();
    error TakasurePool__NothingToRefund();
    error TakasurePool__RefundFailed();
    error TakasurePool__TooEarlytoRefund();
}
