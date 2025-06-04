//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/// @title Roles
/// @notice Roles used in the protocol
library Roles {
    bytes32 internal constant OPERATOR = keccak256("OPERATOR");
    bytes32 internal constant DAO_MULTISIG = keccak256("DAO_MULTISIG");
    bytes32 internal constant KYC_PROVIDER = keccak256("KYC_PROVIDER");
    bytes32 internal constant MODULE_MANAGER = keccak256("MODULE_MANAGER");
    bytes32 internal constant ROUTER = keccak256("ROUTER");
    bytes32 internal constant COUPON_REDEEMER = keccak256("COUPON_REDEEMER");
}
