// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

import {StrategyConfig} from "contracts/types/Strategies.sol";

interface ISFStrategyAggregatorLens {
    function getConfig(address aggregator) external view returns (StrategyConfig memory);
    function positionValue(address aggregator) external view returns (uint256);
    function getPositionDetails(address aggregator) external view returns (bytes memory);
}
