// SPDX-License-Identifier: GPL-3.0

/**
 * @title ModuleErrors
 * @author  Maikel Ordaz
 * @notice  Errors used in the Takasure protocol across more than one module
 */
pragma solidity 0.8.28;

library ModuleErrors {
    error Module__MintFailed();
    error Module__WrongMemberState();
    error Module__TooEarlyToCancel();
    error Module__TooEarlyToDefault();
}
