// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BurnMintTokenPool} from "ccip/contracts/src/v0.8/ccip/pools/BurnMintTokenPool.sol";
import {IBurnMintERC20} from "ccip/contracts/src/v0.8/shared/token/ERC20/IBurnMintERC20.sol";
import {TestnetPoolScriptBase} from "deploy/ccip/testnetPool/TestnetPoolScriptBase.s.sol";

interface ICCIPRouterWithArmProxy {
    function getArmProxy() external view returns (address);
}

/// @notice Deploys a standard BurnMintTokenPool on Arbitrum Sepolia for the new CCIP-compatible SFUSDC testnet token.
contract DeployBurnMintTokenPoolArbSepoliaTestnet is Script, TestnetPoolScriptBase {
    error DeployBurnMintTokenPoolArbSepoliaTestnet__UnsupportedChainId(uint256 chainId);

    uint8 internal constant SFUSDC_DECIMALS = 6;

    function run() external returns (BurnMintTokenPool pool_) {
        uint256 chainId = block.chainid;
        if (chainId != ARB_SEPOLIA_CHAIN_ID) {
            revert DeployBurnMintTokenPoolArbSepoliaTestnet__UnsupportedChainId(chainId);
        }

        address token = _envAddressOr("CCIP_TESTNET_TOKEN", _deploymentAddress(chainId, "SFUSDCCcipTestnet"));
        address ccipRouter = routerAddress.arbSepoliaRouter;
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
}
