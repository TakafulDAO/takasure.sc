// SPDX-License-Identifier: GNU GPLv3

import {RevenueType} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;
interface IRevenueModule {
    function depositRevenue(uint256 newRevenue, RevenueType revenueType) external;
}
