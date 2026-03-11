// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.24;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";
import {SFUSDCMintUSDCOnlyPool} from "deploy/ccip/testnetPool/neededContracts/SFUSDCMintUSDCOnlyPool.sol";

interface ICCIPRouterWithArmProxy {
    function getArmProxy() external view returns (address);
}

/// @notice Deploys the Arbitrum Sepolia inbound-only custom CCIP pool for the legacy SFUSDC token.
contract DeploySFUSDCMintUSDCOnlyPoolArbSepolia is Script, DeployConstants, GetContractAddress {
    error DeploySFUSDCMintUSDCOnlyPoolArbSepolia__UnsupportedChainId(uint256 chainId);
    uint8 internal constant SFUSDC_DECIMALS = 6;

    function run() external returns (SFUSDCMintUSDCOnlyPool pool_) {
        uint256 chainId = block.chainid;
        if (chainId != ARB_SEPOLIA_CHAIN_ID) {
            revert DeploySFUSDCMintUSDCOnlyPoolArbSepolia__UnsupportedChainId(chainId);
        }

        address ccipRouter = routerAddress.arbSepoliaRouter;
        address sfusdc = _getContractAddress(chainId, "SFUSDC");
        address rmnProxy = ICCIPRouterWithArmProxy(ccipRouter).getArmProxy();

        address[] memory allowlist = new address[](0);

        vm.startBroadcast();
        pool_ = new SFUSDCMintUSDCOnlyPool(sfusdc, SFUSDC_DECIMALS, allowlist, rmnProxy, ccipRouter);
        vm.stopBroadcast();

        console2.log("SFUSDC:", sfusdc);
        console2.log("CCIP Router:", ccipRouter);
        console2.log("RMN/ARM Proxy:", rmnProxy);
        console2.log("Pool:", address(pool_));
    }
}
