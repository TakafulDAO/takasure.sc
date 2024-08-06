// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {TSToken} from "contracts/token/TSToken.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";

contract DeployTakasure is Script {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function run() external returns (address proxy) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast();

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
