// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

import {RouteSelection, SwapExecution, SwapRouteData} from "contracts/types/SwapRoutes.sol";

/**
 * @title ISFUniswapV3SwapRouterHelper
 * @author Maikel Ordaz
 * @notice Interface for the Save Funds swap-route helper used by `SFUniswapV3Strategy`.
 */
interface ISFUniswapV3SwapRouterHelper {
    function setSwapV4PoolConfig(uint24 fee, int24 tickSpacing, address hooks) external;

    function decodeSwapRouteData(bytes calldata swapData) external pure returns (SwapRouteData memory routeData_);

    function resolveSwapAmountIn(uint256 requestedAmountIn, uint256 availableAmount)
        external
        pure
        returns (uint256 amountIn_);

    function buildRouteExecution(
        address recipient,
        uint8 routeId,
        uint256 amountIn,
        uint256 amountOutMin,
        bool swapToOther
    ) external view returns (SwapExecution memory execution_);

    function selectBestRoute(
        uint8 routeCount,
        uint8[2] memory routeIds,
        uint256[2] memory amountOutMins,
        uint256 amountIn,
        uint256 deadline,
        uint256 twapMinOut,
        bool swapToOther
    ) external returns (RouteSelection memory selection_);

    function executePreparedSwap(
        address permit2Address,
        address universalRouterAddress,
        address tokenInAddress,
        address expectedOut,
        bytes memory commands,
        bytes[] memory inputs,
        uint256 totalIn,
        uint256 deadline,
        bool emitEvents
    ) external returns (bool ok_, uint256 amountOut_);
}
