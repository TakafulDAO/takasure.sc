// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

interface ITakasurePool {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function prejoins(
        address newMember,
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external;
}
