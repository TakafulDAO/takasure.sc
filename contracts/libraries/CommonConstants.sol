//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/// @title CommonConstants
/// @notice Common constants used in the protocol
/// @dev Constants are gas efficient alternatives to their literal values
library CommonConstants {
    bytes32 internal constant TAKADAO_OPERATOR = keccak256("TAKADAO_OPERATOR");
    bytes32 internal constant DAO_MULTISIG = keccak256("DAO_MULTISIG");
    bytes32 internal constant KYC_PROVIDER = keccak256("KYC_PROVIDER");

    uint256 internal constant MONTH = 30 days;
    uint256 internal constant DAY = 1 days;

    uint256 internal constant DECIMALS_PRECISION = 1e12;
}
