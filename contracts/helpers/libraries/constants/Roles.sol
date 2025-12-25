//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

/// @title Roles
/// @notice Roles used in the protocol
library Roles {
    bytes32 internal constant OPERATOR = keccak256("OPERATOR");
    bytes32 internal constant DAO_MULTISIG = keccak256("DAO_MULTISIG");
    bytes32 internal constant KYC_PROVIDER = keccak256("KYC_PROVIDER");
    bytes32 internal constant PAUSE_GUARDIAN = keccak256("PAUSE_GUARDIAN");
    bytes32 internal constant REVENUE_CLAIMER = keccak256("REVENUE_CLAIMER");
    bytes32 internal constant BACKEND_ADMIN = keccak256("BACKEND_ADMIN");
    bytes32 internal constant KEEPER = keccak256("KEEPER");
}
