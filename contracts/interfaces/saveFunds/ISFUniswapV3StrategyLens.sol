// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFLens
 * @author Maikel Ordaz
 * @notice Facade lens for SaveFunds (vault + aggregator + Uniswap V3 strategy).
 */

pragma solidity 0.8.28;

import {StrategyConfig} from "contracts/types/Strategies.sol";

interface ISFUniswapV3StrategyLens {
    function getConfig(address strategy) external view returns (StrategyConfig memory);
    function positionValue(address strategy) external view returns (uint256);
    function getPositionDetails(address strategy) external view returns (bytes memory);
}
