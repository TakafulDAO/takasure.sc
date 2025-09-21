// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

interface IReferralRewardsModule {
    function calculateReferralRewards(
        uint256 contribution,
        uint256 couponAmount,
        address child,
        address parent,
        uint256 feeAmount
    ) external returns (uint256 newFeeAmount, uint256 discount, uint256 toReferralReserveAmount);
    function rewardParents(address child) external;
}
