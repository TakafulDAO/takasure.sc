// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ModuleState, ProtocolAddressType} from "contracts/types/TakasureTypes.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";

contract Reverts_RevShareModuleTest is Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;

    RevShareModule revShareModule;
    ModuleManager moduleManager;

    IUSDC usdc;
    address module;
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

        SubscriptionModule subscriptions;
        (revShareModule, subscriptions) = moduleDeployer.run(addrMgr);

        module = address(subscriptions);
        moduleManager = modMgr;

        takadao = operatorAddr;

        usdc = IUSDC(config.contributionToken);
    }

    function testRevShareModule_setAvailableDateRevertsIfModuleIsNotEnabled() public {
        vm.prank(moduleManager.owner());
        moduleManager.changeModuleState(address(revShareModule), ModuleState.Paused);

        vm.prank(takadao);
        vm.expectRevert(ModuleErrors.Module__WrongModuleState.selector);
        revShareModule.setAvailableDate(block.timestamp + 1 days);
    }

    function testRevShareModule_setAvailableDateRevertsIfDateIsIncorrect() public {
        vm.prank(takadao);
        vm.expectRevert(RevShareModule.RevShareModule__InvalidDate.selector);
        revShareModule.setAvailableDate(block.timestamp);
    }

    function testRevShareModule_releaseRevenuesRevertsIfModuleIsNotEnabled() public {
        vm.prank(moduleManager.owner());
        moduleManager.changeModuleState(address(revShareModule), ModuleState.Paused);

        vm.prank(takadao);
        vm.expectRevert(ModuleErrors.Module__WrongModuleState.selector);
        revShareModule.releaseRevenues();
    }

    function testRevShareModule_releaseRevenuesRevertWhenAlreadyAvailable() public {
        vm.expectRevert(RevShareModule.RevShareModule__InvalidDate.selector);
        vm.prank(takadao);
        revShareModule.releaseRevenues();
    }

    function testRevShareModule_releaseRevenuesRevertsIfDateIsInvalid() public {
        vm.prank(takadao);
        revShareModule.setAvailableDate(block.timestamp + 30 days);

        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 1);

        vm.prank(takadao);
        vm.expectRevert(RevShareModule.RevShareModule__InvalidDate.selector);
        revShareModule.releaseRevenues();
    }

    function testRevShareModule_sweepNonApprovedDepositsRevertsIfModuleIsNotEnabled() public {
        vm.prank(moduleManager.owner());
        moduleManager.changeModuleState(address(revShareModule), ModuleState.Paused);

        vm.prank(takadao);
        vm.expectRevert(ModuleErrors.Module__WrongModuleState.selector);
        revShareModule.sweepNonApprovedDeposits();
    }

    function testRevShareModule_sweepNonApprovedDepositsRevertsIfThereIsNothingToSweep() public {
        vm.prank(takadao);
        vm.expectRevert(RevShareModule.RevShareModule__NothingToSweep.selector);
        revShareModule.sweepNonApprovedDeposits();
    }

    function testRevShareModule_claimRevenueShareRevertsIfModuleIsNotEnabled() public {
        vm.prank(moduleManager.owner());
        moduleManager.changeModuleState(address(revShareModule), ModuleState.Paused);

        vm.prank(takadao);
        vm.expectRevert(ModuleErrors.Module__WrongModuleState.selector);
        revShareModule.claimRevenueShare();
    }

    function testRevShareModule_claimRevenueShareRevertsIfDateIsInvalid() public {
        vm.prank(takadao);
        revShareModule.setAvailableDate(block.timestamp + 30 days);

        vm.prank(takadao);
        vm.expectRevert(RevShareModule.RevShareModule__RevenuesNotAvailableYet.selector);
        revShareModule.claimRevenueShare();
    }

    function testRevShareModule_notifyRevertOnZeroAmount() public {
        vm.startPrank(module);
        usdc.approve(address(revShareModule), 0);
        vm.expectRevert(RevShareModule.RevShareModule__NotZeroValue.selector);
        revShareModule.notifyNewRevenue(0);
        vm.stopPrank();
    }

    function testRevShareModule_sweepNoExtraReverts() public {
        vm.expectRevert(RevShareModule.RevShareModule__NothingToSweep.selector);
        vm.prank(takadao);
        revShareModule.sweepNonApprovedDeposits();
    }

    // setRewardsDuration: operator-only; duration > 0; cannot change mid-stream; can change after finish; emits event
    function testRevShareModule_setRewardsDurationRevertZero() public {
        vm.expectRevert(RevShareModule.RevShareModule__NotZeroValue.selector);
        vm.prank(takadao);
        revShareModule.setRewardsDuration(0);
    }
}
