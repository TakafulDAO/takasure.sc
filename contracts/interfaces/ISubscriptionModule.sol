// SPDX-License-Identifier: GNU GPLv3

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

pragma solidity 0.8.28;
interface ISubscriptionModule {
    function paySubscription(
        address membersWallet,
        address parentWallet,
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external;
    function refund(address memberWallet) external;
    function transferContributionAfterKyc(
        IERC20 contributionToken,
        address memberWallet,
        address takasureReserve,
        uint256 contributionAfterFee
    ) external;
}
