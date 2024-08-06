// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2, stdJson} from "forge-std/Script.sol";

contract GetContractAddress is Script {
    using stdJson for string;

    uint256 public constant ARB_MAINNET_CHAIN_ID = 42161;
    uint256 public constant ARB_SEPOLIA_CHAIN_ID = 421614;

    function _getContractAddress(
        uint256 chainId,
        string memory contractName
    ) internal view returns (address) {
        string memory chainName;

        if (chainId == ARB_SEPOLIA_CHAIN_ID) {
            chainName = "testnet_arbitrum_sepolia";
        } else if (chainId == ARB_MAINNET_CHAIN_ID) {
            chainName = "mainnet_arbitrum";
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
