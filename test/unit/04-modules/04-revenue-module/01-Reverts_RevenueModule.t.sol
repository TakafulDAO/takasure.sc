// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {RevenueModule} from "contracts/modules/RevenueModule.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {RevenueType, ModuleState} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract Reverts_RevenueModule is Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;

    RevenueModule revenueModule;
    AddressManager addressManager;
    ModuleManager moduleManager;

    address operator;

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        addressesAndRoles = new AddAddressesAndRoles();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addrMgr,
            ModuleManager modMgr
        ) = managersDeployer.run();

        (address operatorAddr, , , , , ) = addressesAndRoles.run(addrMgr, config, address(modMgr));

        (, , , , , revenueModule, ) = moduleDeployer.run(addrMgr);

        addressManager = addrMgr;
        moduleManager = modMgr;
        operator = operatorAddr;
    }

    function testRevenueModule_depositRevenueRevertIfCallerIsWrong() public {
        vm.prank(address(0));
        vm.expectRevert(ModuleErrors.Module__NotAuthorizedCaller.selector);
        revenueModule.depositRevenue(25e6, RevenueType.Contribution);
    }

    function testRevenueModule_depositRevenueRevertIfModuleIsNotEnabled() public {
        vm.prank(address(moduleManager));
        revenueModule.setContractState(ModuleState.Paused);

        vm.prank(operator);
        vm.expectRevert(ModuleErrors.Module__WrongModuleState.selector);
        revenueModule.depositRevenue(25e6, RevenueType.Contribution);
    }
}
