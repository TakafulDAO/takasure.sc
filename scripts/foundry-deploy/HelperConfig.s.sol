//SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {TakaToken} from "../../contracts/token/TakaToken.sol";
import {TakasurePool} from "../../contracts/token/TakasurePool.sol";
import {USDC} from "../../contracts/mocks/USDCmock.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address contributionToken;
        address takaToken;
        address takasurePool;
        uint256 deployerKey;
    }

    NetworkConfig public activeNetworkConfig;

    uint256 public DEFAULT_ANVIL_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    constructor() {
        activeNetworkConfig = getOrCreateAnvilConfig();
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.takaToken != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        USDC usdc = new USDC();
        TakaToken takaToken = new TakaToken();
        TakasurePool takasurePool = new TakasurePool(address(takaToken));
        vm.stopBroadcast();

        return
            NetworkConfig({
                contributionToken: address(usdc),
                takaToken: address(takaToken),
                takasurePool: address(takasurePool),
                deployerKey: DEFAULT_ANVIL_PRIVATE_KEY
            });
    }
}
