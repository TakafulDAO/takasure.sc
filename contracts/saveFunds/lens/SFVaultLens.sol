// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFVaultLens
 * @author Maikel Ordaz
 * @notice View-only helper for SFVault.
 */

pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISFVaultLensTarget} from "contracts/interfaces/saveFunds/ISFVaultLensTarget.sol";

contract SFVaultLens {
    uint256 private constant MAX_BPS = 10_000;

    function getIdleAssets(address vault) external view returns (uint256) {
        return ISFVaultLensTarget(vault).idleAssets();
    }

    function getLastReport(address vault)
        external
        view
        returns (uint256 lastReportTimestamp, uint256 lastReportAssets)
    {
        lastReportTimestamp = uint256(ISFVaultLensTarget(vault).lastReport());
        lastReportAssets = ISFVaultLensTarget(vault).totalAssets();
    }

    function getAggregatorAllocation(address vault) external view returns (uint256) {
        uint256 strat = ISFVaultLensTarget(vault).aggregatorAssets();
        uint256 tvl = ISFVaultLensTarget(vault).idleAssets() + strat;

        if (tvl == 0) return 0;
        return Math.mulDiv(strat, MAX_BPS, tvl);
    }

    function getAggregatorAssets(address vault) external view returns (uint256) {
        return ISFVaultLensTarget(vault).aggregatorAssets();
    }

    function getUserAssets(address vault, address user) external view returns (uint256) {
        uint256 shares = ISFVaultLensTarget(vault).balanceOf(user);
        if (shares == 0) return 0;
        return ISFVaultLensTarget(vault).convertToAssets(shares);
    }

    function getUserShares(address vault, address user) external view returns (uint256) {
        return ISFVaultLensTarget(vault).balanceOf(user);
    }

    function getUserTotalDeposited(address vault, address user) external view returns (uint256) {
        return ISFVaultLensTarget(vault).userTotalDeposited(user);
    }

    function getUserTotalWithdrawn(address vault, address user) external view returns (uint256) {
        return ISFVaultLensTarget(vault).userTotalWithdrawn(user);
    }

    function getUserNetDeposited(address vault, address user) external view returns (uint256) {
        uint256 deposited = ISFVaultLensTarget(vault).userTotalDeposited(user);
        uint256 withdrawn = ISFVaultLensTarget(vault).userTotalWithdrawn(user);
        return deposited > withdrawn ? deposited - withdrawn : 0;
    }

    function getUserPnL(address vault, address user) external view returns (int256) {
        uint256 shares = ISFVaultLensTarget(vault).balanceOf(user);
        uint256 currentAssets = shares == 0 ? 0 : ISFVaultLensTarget(vault).convertToAssets(shares);
        uint256 totalValue = currentAssets + ISFVaultLensTarget(vault).userTotalWithdrawn(user);
        uint256 deposited = ISFVaultLensTarget(vault).userTotalDeposited(user);

        if (totalValue >= deposited) return int256(totalValue - deposited);
        return -int256(deposited - totalValue);
    }

    function getVaultPerformanceSince(address vault, uint256 timestamp) external view returns (int256) {
        uint256 totalShares = ISFVaultLensTarget(vault).totalSupply();
        if (totalShares == 0) return 0;

        uint256 currentAssetsPerShareWad = Math.mulDiv(ISFVaultLensTarget(vault).totalAssets(), 1e18, totalShares);

        uint256 baseAssetsPerShareWad;
        if (timestamp == 0) {
            baseAssetsPerShareWad = 1e18;
        } else if (timestamp <= uint256(ISFVaultLensTarget(vault).lastReport())) {
            baseAssetsPerShareWad = ISFVaultLensTarget(vault).highWaterMark();
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
        return ISFVaultLensTarget(vault).totalAssets();
    }
}
