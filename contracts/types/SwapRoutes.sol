// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

/**
 * @dev Prepared Universal Router execution for a single candidate route.
 */
struct SwapExecution {
    address tokenIn;
    address tokenOut;
    bytes commands;
    bytes[] inputs;
    uint256 totalIn;
}

/**
 * @dev Compact per-swap route bundle passed from the strategy.
 */
struct SwapRouteData {
    uint256 amountIn;
    uint256 deadline;
    uint8 routeCount;
    uint8[2] routeIds;
    uint256[2] amountOutMins;
}

/**
 * @dev Result of quoting all candidate routes for a single background swap.
 */
struct RouteSelection {
    uint256 v3QuotedOut;
    uint256 v4QuotedOut;
    uint256 bestAmountOutMin;
    uint8 bestRouteId;
}
