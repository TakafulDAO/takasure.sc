// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeploySFVault is Script {
    function run() external returns (address proxy) {
        uint256 chainId = block.chainid;
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(chainId);

        vm.startBroadcast();

        // Deploy SFVault
        proxy = Upgrades.deployUUPSProxy(
            "SFVault.sol", abi.encodeCall(SFVault.initialize, (IERC20(config.contributionToken), "SF Vault", "SFV"))
        );

        vm.stopBroadcast();

        return (proxy);
    }
}
