// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract Initialization_RevShareModuleTest is Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;

    RevShareModule revShareModule;
    address takadao;

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        addressesAndRoles = new AddAddressesAndRoles();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addrMgr,
            ModuleManager modMgr
        ) = managersDeployer.run();

        (address operatorAddr, , , , , , ) = addressesAndRoles.run(
            addrMgr,
            config,
            address(modMgr)
        );

        (, , , , , , revShareModule, ) = moduleDeployer.run(addrMgr);

        takadao = operatorAddr;
    }

    function testRevShareModule_availableDate() public view {
        assertEq(revShareModule.revenuesAvailableDate(), block.timestamp);
    }

    function testRevShareModule_nonApprovedDepositsYet() public view {
        assertEq(revShareModule.approvedDeposits(), 0);
    }

    function testRevShareModule_noOneHasInteract() public view {
        assertEq(revShareModule.lastUpdateTime(), 0);
    }

    function testRevShareModule_lastTimeApplicableWhenPfZeroReturnsNow() public view {
        // periodFinish should be zero right after deployment
        assertEq(revShareModule.periodFinish(), 0, "pf must be zero on init");
        // When pf == 0, lastTimeApplicable() should return the current block.timestamp
        assertEq(
            revShareModule.lastTimeApplicable(),
            block.timestamp,
            "should return now when pf==0"
        );
    }

    function testRevShareModule_lastTimeApplicablePfZeroTracksWarp() public {
        assertEq(revShareModule.periodFinish(), 0, "pf must be zero on init");
        vm.warp(block.timestamp + 12345);
        vm.roll(block.number + 1);
        assertEq(
            revShareModule.lastTimeApplicable(),
            block.timestamp,
            "should return now after warp"
        );
    }
}
