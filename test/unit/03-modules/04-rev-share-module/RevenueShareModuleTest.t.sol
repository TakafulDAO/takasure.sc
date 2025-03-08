// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";

contract RevShareModuleTest is Test {
    TestDeployProtocol deployer;
    HelperConfig helperConfig;
    RevShareModule revShareModule;
    address revShareModuleAddress;

    function setUp() public {
        deployer = new TestDeployProtocol();
        (, , , , , , , revShareModuleAddress, , , , helperConfig) = deployer.run();

        revShareModule = RevShareModule(revShareModuleAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
    }
}
