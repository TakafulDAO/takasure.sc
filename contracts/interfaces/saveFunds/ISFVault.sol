// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

interface ISFVault {
    function isTokenWhitelisted(address token) external view returns (bool);
    function investIntoStrategy(uint256 assets, address[] calldata strategies, bytes[] calldata payloads)
        external
        returns (uint256 investedAssets);
    function withdrawFromStrategy(uint256 assets, address[] calldata strategies, bytes[] calldata payloads)
        external
        returns (uint256 withdrawnAssets);
}
