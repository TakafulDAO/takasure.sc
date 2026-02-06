// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

interface ISFUniswapV3StrategyLensTarget {
    function asset() external view returns (address);
    function pool() external view returns (address);
    function otherToken() external view returns (address);
    function vault() external view returns (address);
    function paused() external view returns (bool);
    function positionTokenId() external view returns (uint256);
    function tickLower() external view returns (int24);
    function tickUpper() external view returns (int24);
    function twapWindow() external view returns (uint32);
    function totalAssets() external view returns (uint256);
}
