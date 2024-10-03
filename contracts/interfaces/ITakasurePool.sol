// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

interface ITakasurePool {
    function joinByReferral(
        address newMember,
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external;
}
