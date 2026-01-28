// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

library SFPauseflags {
    bytes1 internal constant LARGE_WITHDRAW_QUEUED_FLAG = 0x01;
    bytes1 internal constant RATE_LIMIT_EXCEEDED_FLAG = 0x02;
    bytes1 internal constant EXECUTE_INVALID_STATE = 0x03;
}
