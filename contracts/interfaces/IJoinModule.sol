//SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

interface IJoinModule {
    function joinPool(
        address mebersWallet,
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external;
    function refund(address memberWallet) external;
}
