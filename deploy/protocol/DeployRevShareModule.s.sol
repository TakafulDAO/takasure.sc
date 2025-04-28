// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {ModuleManager} from "contracts/modules/manager/ModuleManager.sol";

contract DeployRevShareModule is Script {
    function run() external returns (address proxy) {
        uint256 chainId = block.chainid;
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(chainId);

        string
            memory baseUri = "https://ipfs.io/ipfs/QmYLyTRp3uUN8ryGw2NaLPoudicgSJDr4E5DGTn8tLj8gP/";

        vm.startBroadcast();
        proxy = Upgrades.deployUUPSProxy(
            "RevShareModule.sol",
            abi.encodeCall(
                RevShareModule.initialize,
                (
                    config.takadaoOperator,
                    config.kycProvider,
                    address(new ModuleManager()),
                    config.contributionToken
                )
            )
        );

        RevShareModule(proxy).setBaseURI(baseUri);
        vm.stopBroadcast();
    }
}
