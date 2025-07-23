// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ProtocolAddressType} from "contracts/types/TakasureTypes.sol";

contract DeployTakasureReserve is Script {
    function run(
        HelperConfig helperConfig,
        AddressManager addressManager
    ) external returns (TakasureReserve takasureReserve) {
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast(msg.sender);

        // Deploy TakasureReserve
        address takasureReserveImplementation = address(new TakasureReserve());
        address takasureReserveAddress = UnsafeUpgrades.deployUUPSProxy(
            takasureReserveImplementation,
            abi.encodeCall(
                TakasureReserve.initialize,
                (config.contributionToken, address(addressManager))
            )
        );

        takasureReserve = TakasureReserve(takasureReserveAddress);

        addressManager.addProtocolAddress(
            "TAKASURE_RESERVE",
            takasureReserveAddress,
            ProtocolAddressType.Protocol
        );

        addressManager.addProtocolAddress(
            "FEE_CLAIM_ADDRESS",
            config.feeClaimAddress,
            ProtocolAddressType.Admin
        );

        vm.stopBroadcast();

        return (takasureReserve);
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
