//SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

interface ISubscriptionModule {
    function initialize(address _addressManager, string calldata _moduleName) external;
    function paySubscription(address parentWallet) external;
    function paySubscriptionOnBehalfOf(
        address userWallet,
        address parentWallet,
        uint256 couponAmount,
        uint256 membershipStartTime
    ) external;
    function refund(address memberWallet) external;
    function transferSubscriptionToReserve(address memberWallet) external returns (uint256);
    function joinFromReferralGateway(
        address memberWallet,
        address parentWallet,
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external;
}
