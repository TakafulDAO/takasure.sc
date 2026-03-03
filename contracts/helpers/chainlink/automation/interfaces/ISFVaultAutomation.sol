// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

interface ISFVaultAutomation {
    function idleAssets() external view returns (uint256);
    function investIntoStrategy(uint256 assets, address[] calldata strategies, bytes[] calldata payloads)
        external
        returns (uint256 investedAssets);
}
