// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployRevShareNft is Script {
    string baseURI =
        "https://bafybeia2igblodva5p2yknyykmswnh66jysmr67ucnoeqtrlzach3ma34a.ipfs.w3s.link/";

    function run() external returns (address nft) {
        vm.startBroadcast();

        nft = Upgrades.deployUUPSProxy(
            "RevShareNFT.sol",
            abi.encodeCall(RevShareNFT.initialize, (baseURI))
        );

        vm.stopBroadcast();

        return (nft);
    }
}
