// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";

contract DeployRevShareNft is Script {
    function run() external returns (RevShareNFT nft) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast();

        nft = new RevShareNFT(config.takadaoOperator);

        vm.stopBroadcast();

        return (nft);
    }
}
