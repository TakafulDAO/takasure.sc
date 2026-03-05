// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ITokenAdminRegistry} from "ccip/contracts/src/v0.8/ccip/interfaces/ITokenAdminRegistry.sol";
import {TestnetPoolScriptBase} from "deploy/ccip/testnetPool/TestnetPoolScriptBase.s.sol";

interface IRegistryModuleOwnerCustomMinimal {
    function registerAdminViaGetCCIPAdmin(address token) external;
}

/// @notice Self-serve registration + pool binding for testnet SFUSDCCcipTestnet tokens.
contract RegisterAndSetPoolSelfServe is Script, TestnetPoolScriptBase {
    // Chainlink CCIP self-serve registry addresses (testnet), sourced from Chainlink CCIP chains API.
    address internal constant ARB_SEPOLIA_TOKEN_ADMIN_REGISTRY = 0x8126bE56454B628a88C17849B9ED99dd5a11Bd2f;
    address internal constant ARB_SEPOLIA_REGISTRY_MODULE_OWNER_CUSTOM = 0xE625f0b8b0Ac86946035a7729Aba124c8A64cf69;
    address internal constant AVAX_FUJI_TOKEN_ADMIN_REGISTRY = 0xA92053a4a3922084d992fD2835bdBa4caC6877e6;
    address internal constant AVAX_FUJI_REGISTRY_MODULE_OWNER_CUSTOM = 0x97300785aF1edE1343DB6d90706A35CF14aA3d81;
    address internal constant BASE_SEPOLIA_TOKEN_ADMIN_REGISTRY = 0x736D0bBb318c1B27Ff686cd19804094E66250e17;
    address internal constant BASE_SEPOLIA_REGISTRY_MODULE_OWNER_CUSTOM = 0x8A55C61227f26a3e2f217842eCF20b52007bAaBe;
    address internal constant ETH_SEPOLIA_TOKEN_ADMIN_REGISTRY = 0x95F29FEE11c5C55d26cCcf1DB6772DE953B37B82;
    address internal constant ETH_SEPOLIA_REGISTRY_MODULE_OWNER_CUSTOM = 0x62e731218d0D47305aba2BE3751E7EE9E5520790;
    address internal constant OP_SEPOLIA_TOKEN_ADMIN_REGISTRY = 0x1d702b1FA12F347f0921C722f9D9166F00DEB67A;
    address internal constant OP_SEPOLIA_REGISTRY_MODULE_OWNER_CUSTOM = 0x49c4ba01dc6F5090f9df43Ab8F79449Db91A0CBB;
    address internal constant POL_AMOY_TOKEN_ADMIN_REGISTRY = 0x1e73f6842d7afDD78957ac143d1f315404Dd9e5B;
    address internal constant POL_AMOY_REGISTRY_MODULE_OWNER_CUSTOM = 0x84ad5890A63957C960e0F19b0448A038a574936B;

    function run() external {
        uint256 chainId = block.chainid;
        if (!_isSupportedTestnetChainId(chainId)) {
            revert TestnetPoolScriptBase__UnsupportedChainId(chainId);
        }

        address registryAddr = _tokenAdminRegistryByChainId(chainId);
        address registryModuleAddr = _registryModuleOwnerCustomByChainId(chainId);

        address token = _deploymentAddress(chainId, "SFUSDCCcipTestnet");
        address pool = _deploymentAddress(chainId, "BurnMintTokenPool");

        ITokenAdminRegistry registry = ITokenAdminRegistry(registryAddr);
        IRegistryModuleOwnerCustomMinimal registryModule = IRegistryModuleOwnerCustomMinimal(registryModuleAddr);

        vm.startBroadcast();

        try registryModule.registerAdminViaGetCCIPAdmin(token) {
            console2.log("registerAdminViaGetCCIPAdmin: success");
        } catch {
            console2.log("registerAdminViaGetCCIPAdmin: skipped/reverted");
        }

        try registry.acceptAdminRole(token) {
            console2.log("acceptAdminRole: success");
        } catch {
            console2.log("acceptAdminRole: skipped/reverted");
        }

        address currentPool = registry.getPool(token);
        if (currentPool != pool) {
            registry.setPool(token, pool);
            console2.log("setPool: updated");
        } else {
            console2.log("setPool: already configured");
        }

        vm.stopBroadcast();

        console2.log("Registry:", registryAddr);
        console2.log("RegistryModule:", registryModuleAddr);
        console2.log("Token:", token);
        console2.log("Pool:", pool);
        console2.log("Registry.getPool(token):", registry.getPool(token));
    }

    function _tokenAdminRegistryByChainId(uint256 chainId) internal pure returns (address) {
        if (chainId == ARB_SEPOLIA_CHAIN_ID) return ARB_SEPOLIA_TOKEN_ADMIN_REGISTRY;
        if (chainId == AVAX_FUJI_CHAIN_ID) return AVAX_FUJI_TOKEN_ADMIN_REGISTRY;
        if (chainId == BASE_SEPOLIA_CHAIN_ID) return BASE_SEPOLIA_TOKEN_ADMIN_REGISTRY;
        if (chainId == ETH_SEPOLIA_CHAIN_ID) return ETH_SEPOLIA_TOKEN_ADMIN_REGISTRY;
        if (chainId == OP_SEPOLIA_CHAIN_ID) return OP_SEPOLIA_TOKEN_ADMIN_REGISTRY;
        if (chainId == POL_AMOY_CHAIN_ID) return POL_AMOY_TOKEN_ADMIN_REGISTRY;
        revert TestnetPoolScriptBase__UnsupportedChainId(chainId);
    }

    function _registryModuleOwnerCustomByChainId(uint256 chainId) internal pure returns (address) {
        if (chainId == ARB_SEPOLIA_CHAIN_ID) return ARB_SEPOLIA_REGISTRY_MODULE_OWNER_CUSTOM;
        if (chainId == AVAX_FUJI_CHAIN_ID) return AVAX_FUJI_REGISTRY_MODULE_OWNER_CUSTOM;
        if (chainId == BASE_SEPOLIA_CHAIN_ID) return BASE_SEPOLIA_REGISTRY_MODULE_OWNER_CUSTOM;
        if (chainId == ETH_SEPOLIA_CHAIN_ID) return ETH_SEPOLIA_REGISTRY_MODULE_OWNER_CUSTOM;
        if (chainId == OP_SEPOLIA_CHAIN_ID) return OP_SEPOLIA_REGISTRY_MODULE_OWNER_CUSTOM;
        if (chainId == POL_AMOY_CHAIN_ID) return POL_AMOY_REGISTRY_MODULE_OWNER_CUSTOM;
        revert TestnetPoolScriptBase__UnsupportedChainId(chainId);
    }
}
