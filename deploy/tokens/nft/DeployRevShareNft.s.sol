// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployRevShareNft is Script {
    string baseURI = "https://ipfs.io/ipfs/QmQUeGU84fQFknCwATGrexVV39jeVsayGJsuFvqctuav6p/";

    function run() external returns (address nft) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast();

        nft = Upgrades.deployUUPSProxy(
            "RevShareNFT.sol",
            abi.encodeCall(RevShareNFT.initialize, (config.takadaoOperator, baseURI))
        );

        vm.stopBroadcast();

        return (nft);
    }
}
