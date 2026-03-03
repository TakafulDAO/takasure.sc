// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/SFUniswapV3Strategy.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeUniV3Strategy is Script, GetContractAddress {
    function run() external returns (address) {
        address sfUniswapV3StrategyAddress = _getContractAddress(block.chainid, "SFUniswapV3Strategy");
        address oldImplementation = Upgrades.getImplementationAddress(sfUniswapV3StrategyAddress);
        console2.log("Old SFUniswapV3Strategy implementation address: ", oldImplementation);

        vm.startBroadcast();

        // Upgrade SFUniswapV3Strategy
        Upgrades.upgradeProxy(sfUniswapV3StrategyAddress, "SFUniswapV3Strategy.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(sfUniswapV3StrategyAddress);
        console2.log("New SFUniswapV3Strategy implementation address: ", newImplementation);

        return (newImplementation);
    }
}
