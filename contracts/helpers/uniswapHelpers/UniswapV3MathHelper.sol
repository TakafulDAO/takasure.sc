// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFUniswapV3MathHelper
 * @author Maikel Ordaz
 * @notice Helper contract to move heavy Uniswap V3 math out of the strategy implementation bytecode.
 * @dev Deploy once and reuse across strategies.
 * @dev This contract is designed to help reduce the bytecode size of the strategy implementation by
 * offloading complex Uniswap V3 math operations to this helper contract.
 */
pragma solidity 0.8.28;

import {INonfungiblePositionManager} from "contracts/interfaces/helpers/INonfungiblePositionManager.sol";
import {IUniswapV3MathHelper} from "contracts/interfaces/saveFunds/IUniswapV3MathHelper.sol";

import {TickMathV3} from "contracts/helpers/uniswapHelpers/libraries/TickMathV3.sol";
import {LiquidityAmountsV3} from "contracts/helpers/uniswapHelpers/libraries/LiquidityAmountsV3.sol";
import {FullMathV3} from "contracts/helpers/uniswapHelpers/libraries/FullMathV3.sol";

contract UniswapV3MathHelper is IUniswapV3MathHelper {
    /*//////////////////////////////////////////////////////////////
                             MATH WRAPPERS
    //////////////////////////////////////////////////////////////*/

    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160) {
        return TickMathV3.getSqrtRatioAtTick(tick);
    }

    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) external pure returns (uint256 amount0, uint256 amount1) {
        return LiquidityAmountsV3.getAmountsForLiquidity(sqrtRatioX96, sqrtRatioAX96, sqrtRatioBX96, liquidity);
    }

    function mulDiv(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256 result) {
        return FullMathV3.mulDiv(a, b, denominator);
    }

    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256 result) {
        return FullMathV3.mulDivRoundingUp(a, b, denominator);
    }
}
