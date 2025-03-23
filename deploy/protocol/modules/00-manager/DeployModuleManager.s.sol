// SPDX-lICENSE// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ModuleManager} from "contracts/modules/manager/ModuleManager.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";

contract DeployModuleManager is Script {
    function run() external returns (ModuleManager moduleManager) {
        vm.startBroadcast();

        moduleManager = new ModuleManager();

        vm.stopBroadcast();

        return (moduleManager);
    }
}
