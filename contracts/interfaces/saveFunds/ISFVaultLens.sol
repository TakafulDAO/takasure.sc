// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFVaultLens
 * @author Maikel Ordaz
 * @notice View-only helper for SFVault.
 */

pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface ISFVaultLens {
    function totalAssets() external view returns (uint256);
    function idleAssets() external view returns (uint256);
    function aggregatorAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function highWaterMark() external view returns (uint256);
    function lastReport() external view returns (uint64);
    function userTotalDeposited(address user) external view returns (uint256);
    function userTotalWithdrawn(address user) external view returns (uint256);
}
