// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/protocol/SFUniswapV3Strategy.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeSFUniswapV3Strategy is Script, GetContractAddress {
    function run() external returns (address) {
        address strategyAddress = _getContractAddress(block.chainid, "SFUniswapV3Strategy");
        address oldImplementation = Upgrades.getImplementationAddress(strategyAddress);

        console2.log("Old SFUniswapV3Strategy implementation address: ", oldImplementation);

        vm.startBroadcast();

        Upgrades.upgradeProxy(strategyAddress, "SFUniswapV3Strategy.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(strategyAddress);
        console2.log("New SFUniswapV3Strategy implementation address: ", newImplementation);

        return newImplementation;
    }
}
