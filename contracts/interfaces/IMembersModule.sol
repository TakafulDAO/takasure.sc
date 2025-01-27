//SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

interface IMembersModule {
    function payRecurringContribution(address memberWallet) external;
    function cancelMembership(address memberWallet) external;
    function defaultMember(address memberWallet) external;
}
