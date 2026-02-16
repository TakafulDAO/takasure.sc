// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFStrategyAggregatorLens
 * @author Maikel Ordaz
 * @notice View-only helper for SFStrategyAggregator.
 */

pragma solidity 0.8.28;

import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {StrategyConfig, SubStrategy} from "contracts/types/Strategies.sol";
import {ISFStrategyAggregatorLensTarget} from "contracts/interfaces/saveFunds/ISFStrategyAggregatorLensTarget.sol";

contract SFStrategyAggregatorLens {
    function getConfig(address aggregator) external view returns (StrategyConfig memory) {
        ISFStrategyAggregatorLensTarget target = ISFStrategyAggregatorLensTarget(aggregator);
        address vault = target.addressManager().getProtocolAddressByName("PROTOCOL__SF_VAULT").addr;

        return StrategyConfig({asset: target.asset(), vault: vault, pool: address(0), paused: target.paused()});
    }

    function positionValue(address aggregator) external view returns (uint256) {
        SubStrategy[] memory subs = ISFStrategyAggregatorLensTarget(aggregator).getSubStrategies();
        uint256 sum;

        for (uint256 i; i < subs.length; ++i) {
            sum += subs[i].strategy.totalAssets();
        }

        return sum;
    }

    function getPositionDetails(address aggregator) external view returns (bytes memory) {
        SubStrategy[] memory subs = ISFStrategyAggregatorLensTarget(aggregator).getSubStrategies();
        uint256 len = subs.length;

        address[] memory strategies = new address[](len);
        uint16[] memory weights = new uint16[](len);
        bool[] memory actives = new bool[](len);

        for (uint256 i; i < len; ++i) {
            strategies[i] = address(subs[i].strategy);
            weights[i] = subs[i].targetWeightBPS;
            actives[i] = subs[i].isActive;
        }

        return abi.encode(strategies, weights, actives);
    }
}
