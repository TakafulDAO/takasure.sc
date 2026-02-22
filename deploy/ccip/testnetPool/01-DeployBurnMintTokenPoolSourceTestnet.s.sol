// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BurnMintTokenPool} from "ccip/contracts/src/v0.8/ccip/pools/BurnMintTokenPool.sol";
import {IBurnMintERC20} from "ccip/contracts/src/v0.8/shared/token/ERC20/IBurnMintERC20.sol";
import {TestnetPoolScriptBase} from "deploy/ccip/testnetPool/TestnetPoolScriptBase.s.sol";

interface ICCIPRouterWithArmProxy {
    function getArmProxy() external view returns (address);
}

/// @notice Deploys the source-chain BurnMintTokenPool for SFUSDCCcipTestnet on non-ArbSepolia testnets.
contract DeployBurnMintTokenPoolSourceTestnet is Script, TestnetPoolScriptBase {
    error DeployBurnMintTokenPoolSourceTestnet__UnsupportedChainId(uint256 chainId);
    error DeployBurnMintTokenPoolSourceTestnet__ArbSepoliaUsesCustomLegacyPool();

    uint8 internal constant SFUSDC_DECIMALS = 6;

    function run() external returns (BurnMintTokenPool pool_) {
        uint256 chainId = block.chainid;
        if (!_isSupportedTestnetChainId(chainId)) {
            revert DeployBurnMintTokenPoolSourceTestnet__UnsupportedChainId(chainId);
        }
        if (chainId == ARB_SEPOLIA_CHAIN_ID) {
            revert DeployBurnMintTokenPoolSourceTestnet__ArbSepoliaUsesCustomLegacyPool();
        }

        address token = _deploymentAddress(chainId, "SFUSDCCcipTestnet");
        address ccipRouter = _routerByChainId(chainId);
        address rmnProxy = ICCIPRouterWithArmProxy(ccipRouter).getArmProxy();

        address[] memory allowlist = new address[](0);

        vm.startBroadcast();
        pool_ = new BurnMintTokenPool(IBurnMintERC20(token), SFUSDC_DECIMALS, allowlist, rmnProxy, ccipRouter);
        vm.stopBroadcast();

        console2.log("Token:", token);
        console2.log("CCIP Router:", ccipRouter);
        console2.log("RMN/ARM Proxy:", rmnProxy);
        console2.log("BurnMintTokenPool:", address(pool_));
    }

    function _routerByChainId(uint256 chainId) internal view returns (address router_) {
        if (chainId == AVAX_FUJI_CHAIN_ID) return routerAddress.avaxFujiRouter;
        if (chainId == BASE_SEPOLIA_CHAIN_ID) return routerAddress.baseSepoliaRouter;
        if (chainId == ETH_SEPOLIA_CHAIN_ID) return routerAddress.ethSepoliaRouter;
        if (chainId == OP_SEPOLIA_CHAIN_ID) return routerAddress.opSepoliaRouter;
        if (chainId == POL_AMOY_CHAIN_ID) return routerAddress.polAmoyRouter;
        revert DeployBurnMintTokenPoolSourceTestnet__UnsupportedChainId(chainId);
    }
}
