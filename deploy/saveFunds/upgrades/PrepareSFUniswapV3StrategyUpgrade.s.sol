// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Options} from "openzeppelin-foundry-upgrades/Defender.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/protocol/SFUniswapV3Strategy.sol";

contract PrepareSFUniswapV3StrategyUpgrade is Script {
    function run() external returns (address newImplementation) {
        Options memory opts;

        Upgrades.validateUpgrade("SFUniswapV3Strategy.sol", opts);
        console2.log("SFUniswapV3Strategy.sol is upgradeable");

        vm.startBroadcast();

        SFUniswapV3Strategy implementation = new SFUniswapV3Strategy();

        vm.stopBroadcast();

        newImplementation = address(implementation);
        console2.log("Prepared implementation:");
        console2.logAddress(newImplementation);

        return newImplementation;
    }
}
