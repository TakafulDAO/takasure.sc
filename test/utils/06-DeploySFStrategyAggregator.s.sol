// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/SFStrategyAggregator.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";

contract DeploySFStrategyAggregator is Script {
    function run(IAddressManager addressManager, IERC20 asset, uint256 maxTVL, address vault)
        external
        returns (SFStrategyAggregator sfStrategyAggregator)
    {
        vm.startBroadcast(msg.sender);

        // Deploy SFStrategyAggregator
        address sfStrategyAggregatorImplementation = address(new SFStrategyAggregator());

        address sfStrategyAggregatorAddress = UnsafeUpgrades.deployUUPSProxy(
            sfStrategyAggregatorImplementation,
            abi.encodeCall(SFStrategyAggregator.initialize, (addressManager, asset, maxTVL, vault))
        );

        sfStrategyAggregator = SFStrategyAggregator(sfStrategyAggregatorAddress);

        vm.stopBroadcast();

        return (sfStrategyAggregator);
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
