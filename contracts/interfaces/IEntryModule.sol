// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;
interface IEntryModule {
    function joinPool(
        address membersWallet,
        address parentWallet,
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external;
    function refund(address memberWallet) external;
}
