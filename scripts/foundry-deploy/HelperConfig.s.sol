//SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {USDC} from "../../contracts/mocks/USDCmock.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address contributionToken;
        uint256 deployerKey;
        address wakalaClaimAddress;
        address daoOperator;
    }

    NetworkConfig public activeNetworkConfig;

    // Anvil's account 0 private key
    uint256 public DEFAULT_ANVIL_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // Anvil's account 1 public address
    address public wakalaClaimAddress = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    // Anvil's account 2 public address
    address public daoOperator = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    constructor() {
        activeNetworkConfig = getOrCreateAnvilConfig();
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.contributionToken != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        USDC usdc = new USDC();
        vm.stopBroadcast();

        return
            NetworkConfig({
                contributionToken: address(usdc),
                deployerKey: DEFAULT_ANVIL_PRIVATE_KEY,
                wakalaClaimAddress: wakalaClaimAddress,
                daoOperator: daoOperator
            });
    }
}
