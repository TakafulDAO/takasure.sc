// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

library VaultsPauseFlags {
    // Each flag is a single bit. Can use more than one flag with `|` and test them with `&`.
    uint256 internal constant RATE_LIMIT_EXCEEDED_FLAG = 1 << 0; // 0b...0001
    uint256 internal constant LARGE_WITHDRAW_QUEUED_FLAG = 1 << 1; // 0b...0010
    uint256 internal constant EXECUTE_INVALID_STATE = 1 << 2; // 0b...0100
}
