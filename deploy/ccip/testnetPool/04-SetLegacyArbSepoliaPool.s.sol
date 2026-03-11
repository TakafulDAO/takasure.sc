// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ITokenAdminRegistry} from "ccip/contracts/src/v0.8/ccip/interfaces/ITokenAdminRegistry.sol";
import {TestnetPoolScriptBase} from "deploy/ccip/testnetPool/TestnetPoolScriptBase.s.sol";

/// @notice Finalizes legacy Arb Sepolia SFUSDC pool setup after manual admin proposal in TokenAdminRegistry.
contract SetLegacyArbSepoliaPool is Script, TestnetPoolScriptBase {
    error SetLegacyArbSepoliaPool__UnsupportedChainId(uint256 chainId);
    error SetLegacyArbSepoliaPool__MissingRegistryAddress();
    error SetLegacyArbSepoliaPool__PoolAddressZero();

    function run() external {
        uint256 chainId = block.chainid;
        if (chainId != ARB_SEPOLIA_CHAIN_ID) revert SetLegacyArbSepoliaPool__UnsupportedChainId(chainId);

        address registryAddr = _envAddressOr("CCIP_TOKEN_ADMIN_REGISTRY", address(0));
        if (registryAddr == address(0)) revert SetLegacyArbSepoliaPool__MissingRegistryAddress();

        address token = _envAddressOr("CCIP_TESTNET_TOKEN", _deploymentAddress(chainId, "SFUSDC"));
        address defaultPool;
        (defaultPool,) = _tryDeploymentAddress(chainId, "SFUSDCMintUSDCOnlyPool");
        address pool = _envAddressOr("CCIP_LOCAL_POOL", defaultPool);
        if (pool == address(0)) revert SetLegacyArbSepoliaPool__PoolAddressZero();

        ITokenAdminRegistry registry = ITokenAdminRegistry(registryAddr);

        vm.startBroadcast();

        // Manual proposeAdministrator is assumed to be completed already.
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
        console2.log("Legacy SFUSDC:", token);
        console2.log("Custom Pool:", pool);
        console2.log("Registry.getPool(token):", registry.getPool(token));
    }
}
