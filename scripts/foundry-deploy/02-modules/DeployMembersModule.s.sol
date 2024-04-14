// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {MembersModule} from "../../../contracts/modules/MembersModule.sol";
import {HelperConfig} from "../HelperConfig.s.sol";

contract DeployMembersModule is Script {
    address defaultAdmin = makeAddr("defaultAdmin");

    function run() external returns (MembersModule, HelperConfig) {
        HelperConfig config = new HelperConfig();

        uint256 deployerKey = config.activeNetworkConfig();

        vm.startBroadcast(deployerKey);

        MembersModule membersModule = new MembersModule();

        vm.stopBroadcast();

        return (membersModule, config);
    }
}
