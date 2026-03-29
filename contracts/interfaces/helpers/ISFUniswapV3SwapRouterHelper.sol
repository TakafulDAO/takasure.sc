// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

/**
 * @title ISFUniswapV3SwapRouterHelper
 * @author Maikel Ordaz
 * @notice Interface for the Save Funds swap-route helper used by `SFUniswapV3Strategy`.
 */
interface ISFUniswapV3SwapRouterHelper {
    /// @dev Prepared Universal Router execution for a single candidate route.
    struct SwapExecution {
        address tokenIn;
        address tokenOut;
        bytes commands;
        bytes[] inputs;
        uint256 totalIn;
    }

    /// @dev Compact per-swap route bundle passed from the strategy.
    struct SwapRouteData {
        uint256 amountIn;
        uint256 deadline;
        uint8 routeCount;
        uint8[2] routeIds;
        uint256[2] amountOutMins;
    }

    /// @dev Result of quoting all candidate routes for a single background swap.
    struct RouteSelection {
        uint256 v3QuotedOut;
        uint256 v4QuotedOut;
        uint256 bestAmountOutMin;
        uint8 bestRouteId;
    }

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
