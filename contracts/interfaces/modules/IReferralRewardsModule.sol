// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

interface IReferralRewardsModule {
    function calculateReferralRewardsFromSubscriptions(
        uint256 contribution,
        uint256 couponAmount,
        address child,
        address parent,
        uint256 fee
    ) external returns (uint256, uint256);
    function rewardParentsFromSubscriptions(address child) external;
}
