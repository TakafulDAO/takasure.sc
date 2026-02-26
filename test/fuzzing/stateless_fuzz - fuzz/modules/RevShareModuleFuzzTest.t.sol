// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ModuleState} from "contracts/types/States.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";

contract RevShareModuleFuzzTest is Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;

    RevShareModule revShareModule;

    IUSDC usdc;
    address module;
    address takadao;
    address moduleManagerAddress;

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        addressesAndRoles = new AddAddressesAndRoles();

        (HelperConfig.NetworkConfig memory config, AddressManager addrMgr, ModuleManager modMgr) =
            managersDeployer.run();

        (address operatorAddr,,,,,,) = addressesAndRoles.run(addrMgr, config, address(modMgr));

        SubscriptionModule subscriptions;
        (,, revShareModule, subscriptions) = moduleDeployer.run(addrMgr);

        module = address(subscriptions);

        takadao = operatorAddr;

        moduleManagerAddress = addrMgr.getProtocolAddressByName("PROTOCOL__MODULE_MANAGER").addr;
        usdc = IUSDC(config.contributionToken);
    }

    function testUpgradeRevertsIfCallerIsInvalid(address caller) public {
        vm.assume(caller != takadao);
        address newImpl = makeAddr("newImpl");

        vm.prank(caller);
        vm.expectRevert();
        revShareModule.upgradeToAndCall(newImpl, "");
    }

    function testSetAvailableDateRevertsIfCallerIsInvalid(address caller) public {
        vm.assume(caller != takadao);
        uint256 newAvailableDate = block.timestamp + 1 days;

        vm.prank(caller);
        vm.expectRevert();
        revShareModule.setAvailableDate(newAvailableDate);
    }

    function testReleaseRevenuesRevertsIfCallerIsInvalid(address caller) public {
        vm.assume(caller != takadao);

        vm.prank(caller);
        vm.expectRevert();
        revShareModule.releaseRevenues();
    }

    function testSweepNonApprovedDepositsRevertsIfCallerIsInvalid(address caller) public {
        vm.assume(caller != takadao);

        vm.prank(caller);
        vm.expectRevert();
        revShareModule.sweepNonApprovedDeposits();
    }

    function testEmergencyWithdrawRevertsIfCallerIsInvalid(address caller) public {
        vm.assume(caller != takadao);

        vm.prank(caller);
        vm.expectRevert();
        revShareModule.emergencyWithdraw();
    }

    function testNotifyNewRevenueRevertsIfCallerIsInvalid(address caller) public {
        vm.assume(caller != module);
        vm.assume(caller != address(0));

        deal(address(usdc), caller, 1e6);

        vm.startPrank(caller);
        usdc.approve(address(revShareModule), 1e6);
        vm.expectRevert();
        revShareModule.notifyNewRevenue(1e6);
        vm.stopPrank();
    }

    function testRevShareModule_sweepRevertsIfCallerIsInvalid(address caller) public {
        vm.assume(caller != takadao);

        // Some extra to ensure different revert isn’t triggered
        uint256 extra = 100e6;
        deal(address(usdc), address(revShareModule), usdc.balanceOf(address(revShareModule)) + extra);

        vm.expectRevert();
        vm.prank(caller);
        revShareModule.sweepNonApprovedDeposits();
    }

    function testRevShareModule_setRewardsDurationRevertsIfCallerIsInvalid(address caller) public {
        vm.assume(caller != takadao);

        // warp to finish to avoid ActiveStreamOngoing masking the role error
        uint256 pf = revShareModule.periodFinish();
        if (pf == 0 || block.timestamp <= pf) {
            _warp((pf == 0 ? 0 : (pf - block.timestamp)) + 1);
        }

        vm.prank(caller);
        vm.expectRevert();
        revShareModule.setRewardsDuration(123);
    }

    function _warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + 1);
    }
}
