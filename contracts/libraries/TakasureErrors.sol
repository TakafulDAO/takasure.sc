// SPDX-License-Identifier: GPL-3.0

/**
 * @title Errors
 * @author  Maikel Ordaz
 * @notice  This library is used to store the errors of the Takasure protocol
 */
pragma solidity 0.8.25;

library TakasureErrors {
    error TakasurePool__ZeroAddress();
    error TakasurePool__WrongInput();
    error TakasurePool__TransferFailed();
    error TakasurePool__MintFailed();
    error TakasurePool__WrongMemberState();
    error TakasurePool__InvalidDate();
    error TakasurePool__NothingToRefund();
    error TakasurePool__BenefitMultiplierRequestFailed(bytes errorResponse);
    error OnlyDaoOrTakadao();
}
