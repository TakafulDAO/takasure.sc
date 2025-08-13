// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {DeployReserve} from "test/utils/05-DeployReserve.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {RevenueModule} from "contracts/modules/RevenueModule.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {RevenueType, ModuleState} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract Deposit_RevenueModule is Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;
    DeployReserve reserveDeployer;

    TakasureReserve takasureReserve;
    RevenueModule revenueModule;
    AddressManager addressManager;
    ModuleManager moduleManager;
    IUSDC usdc;

    address operator;

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        addressesAndRoles = new AddAddressesAndRoles();
        reserveDeployer = new DeployReserve();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addrMgr,
            ModuleManager modMgr
        ) = managersDeployer.run();

        (address operatorAddr, , , , , ) = addressesAndRoles.run(addrMgr, config, address(modMgr));

        (, , , , , revenueModule, ) = moduleDeployer.run(addrMgr);

        takasureReserve = reserveDeployer.run(config, addrMgr);

        addressManager = addrMgr;
        moduleManager = modMgr;
        operator = operatorAddr;

        usdc = IUSDC(config.contributionToken);

        deal(address(usdc), operator, 1000e6);

        vm.prank(operator);
        usdc.approve(address(revenueModule), 1000e6);
    }

    function testDepositRevenue_FirstDeposit() public {
        // Module must be enabled
        vm.prank(address(moduleManager));
        revenueModule.setContractState(ModuleState.Enabled);

        // First ever deposit (both timestamps are zero)
        vm.prank(operator);
        revenueModule.depositRevenue(100e6, RevenueType.CatLoan);
    }

    function testDepositRevenue_SameDay() public {
        vm.prank(address(moduleManager));
        revenueModule.setContractState(ModuleState.Enabled);

        vm.startPrank(operator);
        revenueModule.depositRevenue(100e6, RevenueType.CatLoan);

        // Same block timestamp → same day
        revenueModule.depositRevenue(50e6, RevenueType.CatLoan);
        vm.stopPrank();
    }

    function testDepositRevenue_NewDaySameMonth() public {
        vm.prank(address(moduleManager));
        revenueModule.setContractState(ModuleState.Enabled);

        vm.startPrank(operator);
        revenueModule.depositRevenue(100e6, RevenueType.CatLoan);

        // Advance 1 day but less than a month
        vm.warp(block.timestamp + 1 days);
        revenueModule.depositRevenue(200e6, RevenueType.CatLoan);
        vm.stopPrank();
    }

    function testDepositRevenue_NewMonth() public {
        vm.prank(address(moduleManager));
        revenueModule.setContractState(ModuleState.Enabled);

        vm.startPrank(operator);
        revenueModule.depositRevenue(100e6, RevenueType.CatLoan);

        // Advance more than a month
        vm.warp(block.timestamp + 31 days);
        revenueModule.depositRevenue(300e6, RevenueType.CatLoan);
        vm.stopPrank();
    }
}
