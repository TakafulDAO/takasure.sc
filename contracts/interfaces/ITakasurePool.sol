// SPDX-License-Identifier: GPL-3.0

import {Member} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.25;

interface ITakasurePool {
    function getMemberFromAddress(address member) external view returns (Member memory);
    function joinByReferral(
        address newMember,
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external;
}
