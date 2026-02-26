// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

import {INonfungiblePositionManager} from "contracts/interfaces/helpers/INonfungiblePositionManager.sol";

interface IUniswapV3MathHelper {
    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160);
    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) external pure returns (uint256 amount0, uint256 amount1);
    function mulDiv(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256 result);
    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256 result);
}
