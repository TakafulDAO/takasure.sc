// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.28;

// Configuration for a protected vault.
struct GuardConfig {
    // Rolling 24h window caps (assets). 0 disables the cap.
    uint256 globalWithdrawCap24hAssets;
    uint256 userWithdrawCap24hAssets;

    // Large-withdraw approval threshold (assets). 0 disables approvals.
    uint256 approvalThresholdAssets;

    // Whether the vault is protected/enabled.
    bool enabled;
}

// Rolling 24h accumulator window.
struct Window {
    uint64 start;
    uint256 withdrawn;
}

enum RequestKind {
    Withdraw, // request originated from withdraw(assets)
    Redeem // request originated from redeem(shares)
}

// Large-withdraw request created by the vault hook.
// TODO: No timelock in v1. Must be added for the Investment Fund use case in future versions.
struct WithdrawalRequest {
    address vault;
    address owner;
    address receiver;

    RequestKind kind;

    // What the user attempted at request time:
    uint256 assetsRequested; // for Withdraw: exact; for Redeem: estimated via previewRedeem
    uint256 sharesRequested; // for Redeem: exact; for Withdraw: estimated via previewWithdraw

    // Lifecycle
    uint64 createdAt;
    bool approved;
    bool executed;
    bool cancelled;
}

