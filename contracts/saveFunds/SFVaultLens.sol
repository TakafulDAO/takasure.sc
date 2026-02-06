// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFVaultLens
 * @author Maikel Ordaz
 * @notice View-only helper for SFVault.
 */

pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISFVaultLens} from "contracts/interfaces/saveFunds/ISFVaultLens.sol";

contract SFVaultLens {
    uint256 private constant MAX_BPS = 10_000;

    function getIdleAssets(address vault) external view returns (uint256) {
        return ISFVaultLens(vault).idleAssets();
    }

    function getLastReport(address vault)
        external
        view
        returns (uint256 lastReportTimestamp, uint256 lastReportAssets)
    {
        lastReportTimestamp = uint256(ISFVaultLens(vault).lastReport());
        lastReportAssets = ISFVaultLens(vault).totalAssets();
    }

    function getAggregatorAllocation(address vault) external view returns (uint256) {
        uint256 strat = ISFVaultLens(vault).aggregatorAssets();
        uint256 tvl = ISFVaultLens(vault).idleAssets() + strat;

        if (tvl == 0) return 0;
        return Math.mulDiv(strat, MAX_BPS, tvl);
    }

    function getAggregatorAssets(address vault) external view returns (uint256) {
        return ISFVaultLens(vault).aggregatorAssets();
    }

    function getUserAssets(address vault, address user) external view returns (uint256) {
        uint256 shares = ISFVaultLens(vault).balanceOf(user);
        if (shares == 0) return 0;
        return ISFVaultLens(vault).convertToAssets(shares);
    }

    function getUserShares(address vault, address user) external view returns (uint256) {
        return ISFVaultLens(vault).balanceOf(user);
    }

    function getUserTotalDeposited(address vault, address user) external view returns (uint256) {
        return ISFVaultLens(vault).userTotalDeposited(user);
    }

    function getUserTotalWithdrawn(address vault, address user) external view returns (uint256) {
        return ISFVaultLens(vault).userTotalWithdrawn(user);
    }

    function getUserNetDeposited(address vault, address user) external view returns (uint256) {
        uint256 deposited = ISFVaultLens(vault).userTotalDeposited(user);
        uint256 withdrawn = ISFVaultLens(vault).userTotalWithdrawn(user);
        return deposited > withdrawn ? deposited - withdrawn : 0;
    }

    function getUserPnL(address vault, address user) external view returns (int256) {
        uint256 shares = ISFVaultLens(vault).balanceOf(user);
        uint256 currentAssets = shares == 0 ? 0 : ISFVaultLens(vault).convertToAssets(shares);
        uint256 totalValue = currentAssets + ISFVaultLens(vault).userTotalWithdrawn(user);
        uint256 deposited = ISFVaultLens(vault).userTotalDeposited(user);

        if (totalValue >= deposited) return int256(totalValue - deposited);
        return -int256(deposited - totalValue);
    }

    function getVaultPerformanceSince(address vault, uint256 timestamp) external view returns (int256) {
        uint256 totalShares = ISFVaultLens(vault).totalSupply();
        if (totalShares == 0) return 0;

        uint256 currentAssetsPerShareWad = Math.mulDiv(ISFVaultLens(vault).totalAssets(), 1e18, totalShares);

        uint256 baseAssetsPerShareWad;
        if (timestamp == 0) {
            baseAssetsPerShareWad = 1e18;
        } else if (timestamp <= uint256(ISFVaultLens(vault).lastReport())) {
            baseAssetsPerShareWad = ISFVaultLens(vault).highWaterMark();
        } else {
            return 0;
        }

        if (baseAssetsPerShareWad == 0) return 0;

        uint256 ratioBps = Math.mulDiv(currentAssetsPerShareWad, MAX_BPS, baseAssetsPerShareWad);

        if (ratioBps >= MAX_BPS) {
            uint256 diff = ratioBps - MAX_BPS;
            if (diff > uint256(type(int256).max)) return type(int256).max;
            return int256(diff);
        } else {
            uint256 diff = MAX_BPS - ratioBps;
            if (diff > uint256(type(int256).max)) return type(int256).min;
            return -int256(diff);
        }
    }

    function getVaultTVL(address vault) external view returns (uint256) {
        return ISFVaultLens(vault).totalAssets();
    }
}
