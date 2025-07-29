// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {ProtocolAddressType} from "contracts/types/TakasureTypes.sol";

contract DeployReserve is Script {
    function run(
        HelperConfig.NetworkConfig memory config,
        AddressManager addressManager
    ) external returns (TakasureReserve reserve) {
        vm.startBroadcast(msg.sender);

        address takasureReserveImplementation = address(new TakasureReserve());
        address takasureReserveAddress = UnsafeUpgrades.deployUUPSProxy(
            takasureReserveImplementation,
            abi.encodeCall(
                TakasureReserve.initialize,
                (config.contributionToken, address(addressManager))
            )
        );

        reserve = TakasureReserve(takasureReserveAddress);

        vm.stopBroadcast();

        vm.startPrank(addressManager.owner());
        addressManager.addProtocolAddress(
            "TAKASURE_RESERVE",
            takasureReserveAddress,
            ProtocolAddressType.Protocol
        );

        vm.stopPrank();

        return (reserve);
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
