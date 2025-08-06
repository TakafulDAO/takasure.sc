// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract DeployRevShareNft is Script, DeployConstants {
    error DeployRevShareNft__UnsupportedChainId();

    function run() external returns (address nft) {
        string
            memory baseURI = "https://bafybeia2igblodva5p2yknyykmswnh66jysmr67ucnoeqtrlzach3ma34a.ipfs.w3s.link/";

        uint256 chainId = block.chainid;
        address owner;

        if (chainId == ARB_MAINNET_CHAIN_ID) {
            owner = 0x3F2bdF387e75C9896F94C6BA1aC36754425aCf5F;
        } else if (chainId == ARB_SEPOLIA_CHAIN_ID) {
            owner = 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1;
        } else {
            revert DeployRevShareNft__UnsupportedChainId();
        }

        vm.startBroadcast();

        nft = Upgrades.deployUUPSProxy(
            "RevShareNFT.sol",
            abi.encodeCall(RevShareNFT.initialize, (baseURI, owner))
        );

        vm.stopBroadcast();

        return (nft);
    }
}
