// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFLens
 * @author Maikel Ordaz
 * @notice Router lens for SaveFunds (vault + aggregator + Uniswap V3 strategy).
 */

pragma solidity 0.8.28;

import {ISFVaultLens} from "contracts/interfaces/saveFunds/ISFVaultLens.sol";
import {ISFStrategyAggregatorLens} from "contracts/interfaces/saveFunds/ISFStrategyAggregatorLens.sol";
import {ISFUniswapV3StrategyLens} from "contracts/interfaces/saveFunds/ISFUniswapV3StrategyLens.sol";

import {StrategyConfig} from "contracts/types/Strategies.sol";

contract SFLens {
    ISFVaultLens public immutable vaultLens;
    ISFStrategyAggregatorLens public immutable aggregatorLens;
    ISFUniswapV3StrategyLens public immutable uniswapLens;

    error SFLens__NotAddressZero();

    constructor(address vaultLens_, address aggregatorLens_, address uniswapLens_) {
        if (vaultLens_ == address(0) || aggregatorLens_ == address(0) || uniswapLens_ == address(0)) {
            revert SFLens__NotAddressZero();
        }
        vaultLens = ISFVaultLens(vaultLens_);
        aggregatorLens = ISFStrategyAggregatorLens(aggregatorLens_);
        uniswapLens = ISFUniswapV3StrategyLens(uniswapLens_);
    }

    /*//////////////////////////////////////////////////////////////
                               VAULT
    //////////////////////////////////////////////////////////////*/

    function vaultGetIdleAssets(address vault) external view returns (uint256) {
        return vaultLens.getIdleAssets(vault);
    }

    function vaultGetLastReport(address vault) external view returns (uint256, uint256) {
        return vaultLens.getLastReport(vault);
    }

    function vaultGetAggregatorAllocation(address vault) external view returns (uint256) {
        return vaultLens.getAggregatorAllocation(vault);
    }

    function vaultGetAggregatorAssets(address vault) external view returns (uint256) {
        return vaultLens.getAggregatorAssets(vault);
    }

    function vaultGetUserAssets(address vault, address user) external view returns (uint256) {
        return vaultLens.getUserAssets(vault, user);
    }

    function vaultGetUserShares(address vault, address user) external view returns (uint256) {
        return vaultLens.getUserShares(vault, user);
    }

    function vaultGetUserTotalDeposited(address vault, address user) external view returns (uint256) {
        return vaultLens.getUserTotalDeposited(vault, user);
    }

    function vaultGetUserTotalWithdrawn(address vault, address user) external view returns (uint256) {
        return vaultLens.getUserTotalWithdrawn(vault, user);
    }

    function vaultGetUserNetDeposited(address vault, address user) external view returns (uint256) {
        return vaultLens.getUserNetDeposited(vault, user);
    }

    function vaultGetUserPnL(address vault, address user) external view returns (int256) {
        return vaultLens.getUserPnL(vault, user);
    }

    function vaultGetVaultPerformanceSince(address vault, uint256 timestamp) external view returns (int256) {
        return vaultLens.getVaultPerformanceSince(vault, timestamp);
    }

    function vaultGetVaultTVL(address vault) external view returns (uint256) {
        return vaultLens.getVaultTVL(vault);
    }

    /*//////////////////////////////////////////////////////////////
                             AGGREGATOR
    //////////////////////////////////////////////////////////////*/

    function aggregatorGetConfig(address aggregator) external view returns (StrategyConfig memory) {
        return aggregatorLens.getConfig(aggregator);
    }

    function aggregatorGetPositionValue(address aggregator) external view returns (uint256) {
        return aggregatorLens.positionValue(aggregator);
    }

    function aggregatorGetPositionDetails(address aggregator) external view returns (bytes memory) {
        return aggregatorLens.getPositionDetails(aggregator);
    }

    /*//////////////////////////////////////////////////////////////
                            UNISWAP V3
    //////////////////////////////////////////////////////////////*/

    function uniswapGetConfig(address strategy) external view returns (StrategyConfig memory) {
        return uniswapLens.getConfig(strategy);
    }

    function uniswapGetPositionValue(address strategy) external view returns (uint256) {
        return uniswapLens.positionValue(strategy);
    }

    function uniswapGetPositionDetails(address strategy) external view returns (bytes memory) {
        return uniswapLens.getPositionDetails(strategy);
    }
}
