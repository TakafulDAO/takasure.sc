// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.24;

import {Script, stdJson, console2} from "forge-std/Script.sol";
import {GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";

abstract contract TestnetPoolScriptBase is Script, GetContractAddress {
    using stdJson for string;

    error TestnetPoolScriptBase__UnsupportedChainId(uint256 chainId);
    error TestnetPoolScriptBase__DeploymentNotFound(string path);

    function _selectorByChainId(uint256 chainId) internal pure returns (uint64) {
        if (chainId == ARB_SEPOLIA_CHAIN_ID) return ARB_SEPOLIA_SELECTOR;
        if (chainId == AVAX_FUJI_CHAIN_ID) return AVAX_FUJI_SELECTOR;
        if (chainId == BASE_SEPOLIA_CHAIN_ID) return BASE_SEPOLIA_SELECTOR;
        if (chainId == ETH_SEPOLIA_CHAIN_ID) return ETH_SEPOLIA_SELECTOR;
        if (chainId == OP_SEPOLIA_CHAIN_ID) return OP_SEPOLIA_SELECTOR;
        if (chainId == POL_AMOY_CHAIN_ID) return POL_AMOY_SELECTOR;
        revert TestnetPoolScriptBase__UnsupportedChainId(chainId);
    }

    function _isSupportedTestnetChainId(uint256 chainId) internal pure returns (bool) {
        return chainId == ARB_SEPOLIA_CHAIN_ID || chainId == AVAX_FUJI_CHAIN_ID || chainId == BASE_SEPOLIA_CHAIN_ID
            || chainId == ETH_SEPOLIA_CHAIN_ID || chainId == OP_SEPOLIA_CHAIN_ID || chainId == POL_AMOY_CHAIN_ID;
    }

    function _chainDeploymentsDir(uint256 chainId) internal pure returns (string memory) {
        if (chainId == ARB_SEPOLIA_CHAIN_ID) return "testnet_arbitrum_sepolia";
        if (chainId == AVAX_FUJI_CHAIN_ID) return "testnet_avalanche_fuji";
        if (chainId == BASE_SEPOLIA_CHAIN_ID) return "testnet_base_sepolia";
        if (chainId == ETH_SEPOLIA_CHAIN_ID) return "testnet_ethereum_sepolia";
        if (chainId == OP_SEPOLIA_CHAIN_ID) return "testnet_optimism_sepolia";
        if (chainId == POL_AMOY_CHAIN_ID) return "testnet_polygon_amoy";
        revert TestnetPoolScriptBase__UnsupportedChainId(chainId);
    }

    function _deploymentAddress(uint256 chainId, string memory contractName) internal view returns (address) {
        return _getContractAddress(chainId, contractName);
    }

    function _tryDeploymentAddress(uint256 chainId, string memory contractName) internal view returns (address, bool) {
        string memory path = string.concat(
            vm.projectRoot(), "/deployments/", _chainDeploymentsDir(chainId), "/", contractName, ".json"
        );
        if (!vm.exists(path)) return (address(0), false);
        return (_getContractAddress(chainId, contractName), true);
    }

    function _envAddressOr(string memory key, address defaultValue) internal returns (address) {
        return vm.envOr(key, defaultValue);
    }

    function _envBoolOr(string memory key, bool defaultValue) internal returns (bool) {
        return vm.envOr(key, defaultValue);
    }

    function _envUintOr(string memory key, uint256 defaultValue) internal returns (uint256) {
        return vm.envOr(key, defaultValue);
    }

    function _defaultTokenNameForChain(uint256 chainId) internal pure returns (string memory) {
        if (chainId == ARB_SEPOLIA_CHAIN_ID) return "SFUSDC";
        if (_isSupportedTestnetChainId(chainId)) return "SFUSDCCcipTestnet";
        revert TestnetPoolScriptBase__UnsupportedChainId(chainId);
    }

    function _defaultPoolNameForChain(uint256 chainId) internal pure returns (string memory) {
        if (chainId == ARB_SEPOLIA_CHAIN_ID) return "SFUSDCMintUSDCOnlyPool";
        if (_isSupportedTestnetChainId(chainId)) return "BurnMintTokenPool";
        revert TestnetPoolScriptBase__UnsupportedChainId(chainId);
    }
}
