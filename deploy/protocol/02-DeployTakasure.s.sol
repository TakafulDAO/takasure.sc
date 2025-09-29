// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployTakasure is Script {
    function run() external returns (address proxy) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        require(
            config.contributionToken != address(0) &&
                config.feeClaimAddress != address(0) &&
                config.daoMultisig != address(0) &&
                config.takadaoOperator != address(0) &&
                config.kycProvider != address(0) &&
                config.pauseGuardian != address(0),
            "No address 0 allowed"
        );

        vm.startBroadcast();

        // Deploy TakasurePool
        proxy = Upgrades.deployUUPSProxy(
            "TakasureReserve.sol",
            abi.encodeCall(TakasureReserve.initialize, (config.contributionToken))
        );

        vm.stopBroadcast();

        return (proxy);
    }
}
