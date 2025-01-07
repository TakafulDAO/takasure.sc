// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";

contract GetContractAddress is Script {
    using stdJson for string;

    uint256 public constant ARB_MAINNET_CHAIN_ID = 42161;
    uint256 public constant AVAX_MAINNET_CHAIN_ID = 43114;
    uint256 public constant BASE_MAINNET_CHAIN_ID = 8453;
    uint256 public constant ETH_MAINNET_CHAIN_ID = 1;
    uint256 public constant OP_MAINNET_CHAIN_ID = 10;
    uint256 public constant POL_MAINNET_CHAIN_ID = 137;

    uint256 public constant ARB_SEPOLIA_CHAIN_ID = 421614;
    uint256 public constant AVAX_FUJI_CHAIN_ID = 43113;
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 public constant ETH_SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant OP_SEPOLIA_CHAIN_ID = 11155420;
    uint256 public constant POL_AMOY_CHAIN_ID = 80002;

    function _getContractAddress(
        uint256 chainId,
        string memory contractName
    ) internal view returns (address) {
        string memory chainName;

        if (chainId == ARB_MAINNET_CHAIN_ID) {
            chainName = "mainnet_arbitrum_one";
        } else if (chainId == AVAX_MAINNET_CHAIN_ID) {
            chainName = "mainnet_avax";
        } else if (chainId == BASE_MAINNET_CHAIN_ID) {
            chainName = "mainnet_base";
        } else if (chainId == ETH_MAINNET_CHAIN_ID) {
            chainName = "mainnet_ethereum";
        } else if (chainId == OP_MAINNET_CHAIN_ID) {
            chainName = "mainnet_optimism";
        } else if (chainId == POL_MAINNET_CHAIN_ID) {
            chainName = "mainnet_polygon";
        } else if (chainId == ARB_SEPOLIA_CHAIN_ID) {
            chainName = "testnet_arbitrum_sepolia";
        } else if (chainId == AVAX_FUJI_CHAIN_ID) {
            chainName = "testnet_avax_fuji";
        } else if (chainId == BASE_SEPOLIA_CHAIN_ID) {
            chainName = "testnet_base_sepolia";
        } else if (chainId == ETH_SEPOLIA_CHAIN_ID) {
            chainName = "testnet_ethereum_sepolia";
        } else if (chainId == OP_SEPOLIA_CHAIN_ID) {
            chainName = "testnet_optimism_sepolia";
        } else if (chainId == POL_AMOY_CHAIN_ID) {
            chainName = "testnet_polygon_amoy";
        } else {
            revert("Invalid chainId");
        }

        string memory root = vm.projectRoot();
        string memory path = string.concat(
            root,
            "/deployments/",
            chainName,
            "/",
            contractName,
            ".json"
        );
        string memory json = vm.readFile(path);
        address contractAddress = json.readAddress(".address");
        console2.log(contractName, "address:");
        console2.logAddress(contractAddress);
        console2.log("====================================");

        return contractAddress;
    }
}
