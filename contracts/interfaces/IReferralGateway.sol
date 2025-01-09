// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

interface IReferralGateway {
    function checkCaller(address caller, uint256 callUint) external;
}
