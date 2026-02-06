// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFUniswapV3StrategyLens
 * @author Maikel Ordaz
 * @notice View-only helper for SFUniswapV3Strategy.
 */

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {ISFUniswapV3StrategyLens} from "contracts/interfaces/saveFunds/ISFUniswapV3StrategyLens.sol";

import {TickMathV3} from "contracts/helpers/uniswapHelpers/libraries/TickMathV3.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StrategyConfig} from "contracts/types/Strategies.sol";

contract SFUniswapV3StrategyLens {
    function getConfig(address strategy) external view returns (StrategyConfig memory) {
        ISFUniswapV3StrategyLens target = ISFUniswapV3StrategyLens(strategy);
        return
            StrategyConfig({asset: target.asset(), vault: target.vault(), pool: target.pool(), paused: target.paused()});
    }

    function getPositionDetails(address strategy) external view returns (bytes memory) {
        ISFUniswapV3StrategyLens target = ISFUniswapV3StrategyLens(strategy);
        return abi.encode(uint8(1), target.positionTokenId(), target.pool(), target.tickLower(), target.tickUpper());
    }

    function positionValue(address strategy) external view returns (uint256) {
        ISFUniswapV3StrategyLens target = ISFUniswapV3StrategyLens(strategy);

        uint256 total = target.totalAssets();
        if (total == 0) return 0;

        address underlying = target.asset();
        address other = target.otherToken();
        uint160 sqrtPriceX96 = _valuationSqrtPriceX96(target.pool(), target.twapWindow());

        uint256 idleUnderlying = IERC20(underlying).balanceOf(strategy);
        uint256 idleOther = IERC20(other).balanceOf(strategy);
        uint256 idleOtherValue =
            _quoteOtherAsUnderlyingAtSqrtPrice(underlying, other, target.pool(), idleOther, sqrtPriceX96);

        uint256 idleTotal = idleUnderlying + idleOtherValue;
        if (total <= idleTotal) return 0;

        return total - idleTotal;
    }

    function _valuationSqrtPriceX96(address pool, uint32 window) internal view returns (uint160 sqrtPriceX96_) {
        IUniswapV3Pool uniPool = IUniswapV3Pool(pool);

        if (window == 0) {
            (sqrtPriceX96_,,,,,,) = uniPool.slot0();
            return sqrtPriceX96_;
        }

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;

        try uniPool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int56 secs = int56(uint56(window));

            int24 avgTick = int24(delta / secs);
            if (delta < 0 && (delta % secs != 0)) avgTick--;

            sqrtPriceX96_ = TickMathV3.getSqrtRatioAtTick(avgTick);
            return sqrtPriceX96_;
        } catch {
            (sqrtPriceX96_,,,,,,) = uniPool.slot0();
            return sqrtPriceX96_;
        }
    }

    function _quoteOtherAsUnderlyingAtSqrtPrice(
        address underlying,
        address other,
        address pool,
        uint256 amountOther,
        uint160 sqrtPriceX96
    ) internal view returns (uint256) {
        if (amountOther == 0) return 0;
        if (underlying == other) return amountOther;

        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();

        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 q192 = 1 << 192;

        if (other == token0 && underlying == token1) {
            return Math.mulDiv(amountOther, priceX192, q192);
        } else if (other == token1 && underlying == token0) {
            return Math.mulDiv(amountOther, q192, priceX192);
        } else {
            revert();
        }
    }
}
