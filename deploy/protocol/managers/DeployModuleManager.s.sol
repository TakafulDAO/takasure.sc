// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployModuleManager is Script, GetContractAddress {
    function run() external returns (address proxy) {
        address addressManager = _getContractAddress(block.chainid, "AddressManager");

        vm.startBroadcast();

        // Deploy Module Manager
        proxy =
            Upgrades.deployUUPSProxy("ModuleManager.sol", abi.encodeCall(ModuleManager.initialize, (addressManager)));

        vm.stopBroadcast();

        return (proxy);
    }
}
