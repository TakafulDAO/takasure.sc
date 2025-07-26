// SPDX-License-Identifier: GNU GPLv3

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AssociationMember} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;
interface ISubscriptionModule {
    function joinFromReferralGateway(
        address memberWallet,
        address parentWallet,
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external;
    function paySubscription(
        address membersWallet,
        address parentWallet,
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external;
    function refund(address memberWallet) external;
    function transferSubscriptionToReserve(address memberWallet) external returns (uint256);
    function getAssociationMember(
        address memberWallet
    ) external view returns (AssociationMember memory);
    function modifyAssociationMember(AssociationMember memory member) external;
}
