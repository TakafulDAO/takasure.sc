// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployAddressManager is Script {
    // address constant MULTISIG_ADDRESS = 0x3F2bdF387e75C9896F94C6BA1aC36754425aCf5F; // mainnet
    address constant MULTISIG_ADDRESS = 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1;

    function run() external returns (address proxy) {
        vm.startBroadcast();

        // Deploy TakasurePool
        proxy = Upgrades.deployUUPSProxy(
            "AddressManager.sol", abi.encodeCall(AddressManager.initialize, (MULTISIG_ADDRESS))
        );

        vm.stopBroadcast();

        return (proxy);
    }
}
