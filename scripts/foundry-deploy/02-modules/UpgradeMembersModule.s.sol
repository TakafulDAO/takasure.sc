// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {MembersModule} from "../../../contracts/modules/MembersModule.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {HelperConfig} from "../HelperConfig.s.sol";
import {DevOpsTools} from "lib/foundry-devops/src/DevOpsTools.sol";

contract UpgradeMembersModule is Script {
    address defaultAdmin = makeAddr("defaultAdmin");

    function run() external returns (address) {
        HelperConfig config = new HelperConfig();

        address mostRecentDeployedProxy = DevOpsTools.get_most_recent_deployment(
            "ERC1967Proxy",
            block.chainid
        );

        (, , uint256 deployerKey) = config.activeNetworkConfig();

        vm.startBroadcast(deployerKey);

        MembersModule newMembersModule = new MembersModule();

        MembersModule proxy = MembersModule(payable(mostRecentDeployedProxy));
        proxy.upgradeTo(address(newMembersModule));

        vm.stopBroadcast();

        return (address(proxy));
    }
}
