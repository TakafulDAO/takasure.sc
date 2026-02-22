// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ITokenAdminRegistry} from "ccip/contracts/src/v0.8/ccip/interfaces/ITokenAdminRegistry.sol";
import {TestnetPoolScriptBase} from "deploy/ccip/testnetPool/TestnetPoolScriptBase.s.sol";

interface IRegistryModuleOwnerCustomMinimal {
    function registerAdminViaGetCCIPAdmin(address token) external;
}

/// @notice Self-serve registration + pool binding for source-chain SFUSDCCcipTestnet tokens.
/// @dev Requires CCIP TokenAdminRegistry and RegistryModuleOwnerCustom addresses via env vars.
contract RegisterAndSetPoolSelfServe is Script, TestnetPoolScriptBase {
    error RegisterAndSetPoolSelfServe__MissingRegistryAddress();
    error RegisterAndSetPoolSelfServe__MissingRegistryModuleAddress();
    error RegisterAndSetPoolSelfServe__PoolAddressZero();
    error RegisterAndSetPoolSelfServe__ArbSepoliaLegacyTokenRequiresManualPath();

    function run() external {
        uint256 chainId = block.chainid;
        if (!_isSupportedTestnetChainId(chainId)) {
            revert TestnetPoolScriptBase__UnsupportedChainId(chainId);
        }
        if (chainId == ARB_SEPOLIA_CHAIN_ID) {
            revert RegisterAndSetPoolSelfServe__ArbSepoliaLegacyTokenRequiresManualPath();
        }

        address registryAddr = _envAddressOr("CCIP_TOKEN_ADMIN_REGISTRY", address(0));
        address registryModuleAddr = _envAddressOr("CCIP_REGISTRY_MODULE_OWNER_CUSTOM", address(0));
        if (registryAddr == address(0)) revert RegisterAndSetPoolSelfServe__MissingRegistryAddress();
        if (registryModuleAddr == address(0)) revert RegisterAndSetPoolSelfServe__MissingRegistryModuleAddress();

        address token = _envAddressOr("CCIP_TESTNET_TOKEN", _deploymentAddress(chainId, "SFUSDCCcipTestnet"));
        address defaultPool;
        (defaultPool,) = _tryDeploymentAddress(chainId, "BurnMintTokenPool");
        address pool = _envAddressOr("CCIP_LOCAL_POOL", defaultPool);
        if (pool == address(0)) revert RegisterAndSetPoolSelfServe__PoolAddressZero();

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
}
