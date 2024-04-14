// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MembersModule} from "../../../../contracts/modules/MembersModule.sol";
import {DeployMembersModule} from "../../../../scripts/foundry-deploy/02-modules/DeployMembersModule.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract MembesModuleTest is StdCheats, Test {
    DeployMembersModule deployer;
    MembersModule membersModule;

    function setUp() public {
        deployer = new DeployMembersModule();
        address proxy = deployer.run();

        membersModule = MembersModule(proxy);
    }
}
