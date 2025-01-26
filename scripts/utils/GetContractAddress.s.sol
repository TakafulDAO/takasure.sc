// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract GetContractAddress is Script, DeployConstants {
    using stdJson for string;

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
