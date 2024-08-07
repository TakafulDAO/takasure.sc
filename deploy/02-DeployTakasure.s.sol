// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";

contract DeployTakasure is Script {

    function run() external returns (address proxy) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast();

        // Deploy TakasurePool
        proxy = Upgrades.deployUUPSProxy(
            "TakasurePool.sol",
            abi.encodeCall(
                TakasurePool.initialize,
                (
                    config.contributionToken,
                    config.feeClaimAddress,
                    config.daoOperator,
                    config.tokenAdmin,
                    config.tokenName,
                    config.tokenSymbol
                )
            )
        );

        vm.stopBroadcast();

        return (proxy);
    }
}
