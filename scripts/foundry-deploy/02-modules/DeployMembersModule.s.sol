// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {MembersModule} from "../../../contracts/modules/MembersModule.sol";
import {HelperConfig} from "../HelperConfig.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployMembersModule is Script {
    address defaultAdmin = makeAddr("defaultAdmin");

    function run() external returns (address) {
        HelperConfig config = new HelperConfig();

        (address usdc, , address takasurePool, uint256 deployerKey) = config.activeNetworkConfig();

        vm.startBroadcast(deployerKey);

        MembersModule membersModule = new MembersModule();
        ERC1967Proxy proxy = new ERC1967Proxy(address(membersModule), "");

        MembersModule(address(proxy)).initialize(usdc, takasurePool);

        vm.stopBroadcast();

        return (address(proxy));
    }
}
