//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/// @title ModuleConstants
/// @notice Common constants used in the protocol
/// @dev Constants are gas efficient alternatives to their literal values
library ModuleConstants {
    // Time constants
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant MONTH = 30 days;
    uint256 internal constant DAY = 1 days;

    // Association module constants
    uint256 internal constant ASSOCIATION_SUBSCRIPTION = 25e6; // 25 USDC in six decimals
    uint256 internal constant ASSOCIATION_SUBSCRIPTION_FEE = 27; // 27% service fee, in percentage

    // Contribution constants
    uint256 internal constant DECIMALS_CONVERSION_FACTOR = 1e12;
    uint256 internal constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution deducted from contribution
    uint256 internal constant REFERRAL_RESERVE = 5; // 5% of contribution to Referral Reserve

    uint256 internal constant DECIMAL_REQUIREMENT_PRECISION_USDC = 1e4; // 4 decimals to receive at minimum 0.01 USDC
    uint256 internal constant DEFAULT_MEMBERSHIP_DURATION = 5 * (365 days); // 5 year
}
