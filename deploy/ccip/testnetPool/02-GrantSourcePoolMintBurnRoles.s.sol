// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TestnetPoolScriptBase} from "deploy/ccip/testnetPool/TestnetPoolScriptBase.s.sol";

interface ISFUSDCCcipTestnetRoles {
    function grantMintAndBurnRoles(address account) external;
    function isMinter(address account) external view returns (bool);
    function isBurner(address account) external view returns (bool);
}

/// @notice Grants mint/burn roles on source-chain SFUSDCCcipTestnet to the source token pool.
/// @dev Intended for Fuji/BaseSepolia/EthSepolia/OpSepolia/Amoy (not Arbitrum Sepolia legacy token).
contract GrantSourcePoolMintBurnRoles is Script, TestnetPoolScriptBase {
    error GrantSourcePoolMintBurnRoles__ArbSepoliaLegacyTokenDoesNotUseThisFlow();
    error GrantSourcePoolMintBurnRoles__PoolAddressZero();

    function run() external {
        uint256 chainId = block.chainid;
        if (chainId == ARB_SEPOLIA_CHAIN_ID) {
            revert GrantSourcePoolMintBurnRoles__ArbSepoliaLegacyTokenDoesNotUseThisFlow();
        }
        if (!_isSupportedTestnetChainId(chainId)) revert TestnetPoolScriptBase__UnsupportedChainId(chainId);

        address token = _envAddressOr("CCIP_TESTNET_TOKEN", _deploymentAddress(chainId, "SFUSDCCcipTestnet"));

        address defaultPool;
        (defaultPool,) = _tryDeploymentAddress(chainId, "BurnMintTokenPool");
        address pool = _envAddressOr("CCIP_LOCAL_POOL", defaultPool);
        if (pool == address(0)) revert GrantSourcePoolMintBurnRoles__PoolAddressZero();

        vm.startBroadcast();
        ISFUSDCCcipTestnetRoles(token).grantMintAndBurnRoles(pool);
        vm.stopBroadcast();

        bool minter = ISFUSDCCcipTestnetRoles(token).isMinter(pool);
        bool burner = ISFUSDCCcipTestnetRoles(token).isBurner(pool);

        console2.log("Token:", token);
        console2.log("Pool :", pool);
        console2.log("isMinter:", minter);
        console2.log("isBurner:", burner);
    }
}
