// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

interface ISFUniV3StrategyAutomationView {
    function asset() external view returns (address);
    function otherToken() external view returns (address);
    function pool() external view returns (address);
    function tickLower() external view returns (int24);
    function tickUpper() external view returns (int24);
    function twapWindow() external view returns (uint32);
}
