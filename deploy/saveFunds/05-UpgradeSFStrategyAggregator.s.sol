// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/protocol/SFStrategyAggregator.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeSFStrategyAggregator is Script, GetContractAddress {
    function run() external returns (address) {
        address aggregatorAddress = _getContractAddress(block.chainid, "SFStrategyAggregator");
        address oldImplementation = Upgrades.getImplementationAddress(aggregatorAddress);

        console2.log("Old SFStrategyAggregator implementation address: ", oldImplementation);

        vm.startBroadcast();

        Upgrades.upgradeProxy(aggregatorAddress, "SFStrategyAggregator.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(aggregatorAddress);
        console2.log("New SFStrategyAggregator implementation address: ", newImplementation);

        return newImplementation;
    }
}
