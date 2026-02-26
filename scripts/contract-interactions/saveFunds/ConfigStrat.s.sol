// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/SFUniswapV3Strategy.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract ConfigStrat is Script, GetContractAddress {
    function run() public {
        address aggregatorAddress = _getContractAddress(block.chainid, "SFStrategyAggregator");
        address uniV3Strat = _getContractAddress(block.chainid, "SFUniswapV3Strategy");
        SFStrategyAggregator aggregator = SFStrategyAggregator(aggregatorAddress);
        address[] memory strategies = new address[](1);
        uint16[] memory weights = new uint16[](1);
        bool[] memory active = new bool[](1);
        strategies[0] = uniV3Strat;
        weights[0] = 10_000;
        active[0] = true;

        vm.startBroadcast();

        aggregator.setConfig(abi.encode(strategies, weights, active));

        vm.stopBroadcast();
    }
}
