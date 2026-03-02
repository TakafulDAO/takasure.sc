//SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

interface ISubscriptionModule {
    function initialize(address _addressManager, string calldata _moduleName) external;
    function addAssociationPlan(uint256 planPrice) external;
    function removeAssociationPlan(uint256 planPrice) external;
    function disableAssociationPlan(uint256 planPrice) external;
    function joinFromReferralGateway(
        address userWallet,
        address parentWallet,
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external;
    function paySubscription(uint256 planPrice, address parentWallet) external;
    function paySubscriptionOnBehalfOf(
        address userWallet,
        address parentWallet,
        uint256 planPrice,
        uint256 couponAmount,
        uint256 membershipStartTime
    ) external;
    function refund(address memberWallet) external;
    function transferSubscriptionToReserve(address memberWallet) external returns (uint256);
    function getAssociationPlans() external view returns (uint256[] memory plans_);
}
