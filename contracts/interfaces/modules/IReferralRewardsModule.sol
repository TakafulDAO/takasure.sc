// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

interface IReferralRewardsModule {
    function referralDiscountEnabled() external view returns (bool);
    function childToParent(address child) external view returns (address);
    function historicParentRewardsByChild(address parent, address child) external view returns (uint256);
    function initialize(address _addressManager, string calldata _moduleName) external;
    function switchReferralRewards() external;
    function switchReferralDiscount() external;
    function calculateReferralRewards(
        uint256 contribution,
        uint256 couponAmount,
        address child,
        address parent,
        uint256 feeAmount
    ) external returns (uint256 newFeeAmount_, uint256 discount_, uint256 toReferralReserveAmount_);
    function rewardParents(address child) external;
}
