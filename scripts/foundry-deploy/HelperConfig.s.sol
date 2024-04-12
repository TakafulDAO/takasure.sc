//SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        uint256 deployerKey;
    }

    NetworkConfig public activeNetworkConfig;

    uint256 public DEFAULT_ANVIL_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    constructor() {
        activeNetworkConfig = getOrCreateAnvilConfig();
    }

    function getOrCreateAnvilConfig() public view returns (NetworkConfig memory) {
        // Write here a condition to check if the network config is already set
        // if (condition {
        //     return activeNetworkConfig;
        // }

        // If some mocks needs to be deployed locally for testing, they can be deployed here
        // vm.startBroadcast();
        // Deploy Mocks
        // vm.stopBroadcast();

        return NetworkConfig({deployerKey: DEFAULT_ANVIL_PRIVATE_KEY});
    }
}
