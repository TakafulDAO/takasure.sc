// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployTakasureReserve is Script, GetContractAddress {
    function run() external returns (address takasureReserveProxy) {
        address moduleManager = _getContractAddress(block.chainid, "ModuleManager");

        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        require(
            config.contributionToken != address(0) &&
                config.feeClaimAddress != address(0) &&
                config.daoMultisig != address(0) &&
                config.takadaoOperator != address(0) &&
                config.kycProvider != address(0) &&
                config.pauseGuardian != address(0) &&
                config.tokenAdmin != address(0),
            "No address 0 allowed"
        );

        require(moduleManager != address(0), "Deploy ModuleManager first");

        vm.startBroadcast();

        // Deploy TakasureReserve
        takasureReserveProxy = Upgrades.deployUUPSProxy(
            "TakasureReserve.sol",
            abi.encodeCall(
                TakasureReserve.initialize,
                (
                    config.contributionToken,
                    config.feeClaimAddress,
                    config.daoMultisig,
                    config.takadaoOperator,
                    config.kycProvider,
                    config.pauseGuardian,
                    config.tokenAdmin,
                    moduleManager,
                    config.tokenName,
                    config.tokenSymbol
                )
            )
        );

        vm.stopBroadcast();

        return (takasureReserveProxy);
    }
}
