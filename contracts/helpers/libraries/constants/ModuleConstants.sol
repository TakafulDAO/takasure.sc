//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/// @title ModuleConstants
/// @notice Common constants used in the protocol
/// @dev Constants are gas efficient alternatives to their literal values
library ModuleConstants {
    bytes32 internal constant OPERATOR = keccak256("OPERATOR");
    bytes32 internal constant DAO_MULTISIG = keccak256("DAO_MULTISIG");
    bytes32 internal constant KYC_PROVIDER = keccak256("KYC_PROVIDER");
    bytes32 internal constant MODULE_MANAGER = keccak256("MODULE_MANAGER");
    bytes32 internal constant ROUTER = keccak256("ROUTER");
    bytes32 internal constant COUPON_REDEEMER = keccak256("COUPON_REDEEMER");

    uint256 internal constant MONTH = 30 days;
    uint256 internal constant DAY = 1 days;

    uint256 internal constant DECIMALS_CONVERSION_FACTOR = 1e12;
    uint256 internal constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution deducted from contribution
    uint256 internal constant REFERRAL_RESERVE = 5; // 5% of contribution to Referral Reserve

    uint256 internal constant DECIMAL_REQUIREMENT_PRECISION_USDC = 1e4; // 4 decimals to receive at minimum 0.01 USDC
    uint256 internal constant DEFAULT_MEMBERSHIP_DURATION = 5 * (365 days); // 5 year
}
