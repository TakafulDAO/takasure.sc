// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/SFStrategyAggregator.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeSFStrategyAggregator is Script, GetContractAddress {
    function run() external returns (address) {
        address sfStrategyAggregatorAddress = _getContractAddress(block.chainid, "SFStrategyAggregator");
        address oldImplementation = Upgrades.getImplementationAddress(sfStrategyAggregatorAddress);
        console2.log("Old SFStrategyAggregator implementation address: ", oldImplementation);

        vm.startBroadcast();

        // Upgrade SFStrategyAggregator
        Upgrades.upgradeProxy(sfStrategyAggregatorAddress, "SFStrategyAggregator.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(sfStrategyAggregatorAddress);
        console2.log("New SFStrategyAggregator implementation address: ", newImplementation);

        return (newImplementation);
    }
}
