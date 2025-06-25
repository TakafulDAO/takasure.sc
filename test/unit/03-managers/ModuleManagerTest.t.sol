// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {IsModule, IsNotModule} from "test/mocks/ModuleMocks.sol";

import {ModuleState} from "contracts/types/TakasureTypes.sol";

contract ModuleManagerTest is Test {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    ModuleManager moduleManager;
    IsModule isModule;
    IsNotModule isNotModule;
    address moduleManagerOwner = makeAddr("moduleManagerOwner");
    address addressManager;

    enum State {
        Unset,
        Disabled,
        Enabled,
        Paused,
        Deprecated
    }

    event OnNewModule(address newModuleAddr);
    event OnModuleStateChanged(
        address indexed moduleAddress,
        ModuleState oldState,
        ModuleState newState
    );

    function setUp() public {
        deployer = new TestDeployProtocol();
        (address takasureReserveProxy, , , , , , , , , ) = deployer.run();

        takasureReserve = TakasureReserve(takasureReserveProxy);
        addressManager = address(takasureReserve.addressManager());

        vm.startPrank(moduleManagerOwner);
        address moduleManagerImplementation = address(new ModuleManager());
        address moduleManagerProxy = UnsafeUpgrades.deployUUPSProxy(
            moduleManagerImplementation,
            abi.encodeCall(ModuleManager.initialize, (takasureReserveProxy))
        );
        vm.stopPrank();

        moduleManager = ModuleManager(moduleManagerProxy);

        isModule = new IsModule();
        isNotModule = new IsNotModule();
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    function testAddAddressZeroAsModuleReverts() public {
        vm.prank(addressManager);
        vm.expectRevert(ModuleManager.ModuleManager__AddressZeroNotAllowed.selector);
        moduleManager.addModule(address(0));
    }

    function testAddModuleTwiceReverts() public {
        vm.startPrank(addressManager);
        moduleManager.addModule(address(isModule));
        vm.expectRevert(ModuleManager.ModuleManager__AlreadyModule.selector);
        moduleManager.addModule(address(isModule));
        vm.stopPrank();
    }

    function testOnlyOwnerCanAddModules() public {
        address notOwner = makeAddr("notOwner");

        vm.prank(notOwner);
        vm.expectRevert();
        moduleManager.addModule(address(0));
    }

    function testAddContractIsNotModuleReverts() public {
        vm.prank(addressManager);
        vm.expectRevert(ModuleManager.ModuleManager__NotModule.selector);
        moduleManager.addModule(address(isNotModule));
    }

    modifier addModule() {
        vm.prank(addressManager);
        moduleManager.addModule(address(isModule));
        _;
    }

    function testOnlyOwnerCanChangeModuleState() public addModule {
        address notOwner = makeAddr("notOwner");

        vm.prank(notOwner);
        vm.expectRevert();
        moduleManager.changeModuleState(address(isModule), ModuleState.Enabled);
    }

    function testChangeStateFromDeprecatedReverts() public addModule {
        vm.startPrank(moduleManagerOwner);
        moduleManager.changeModuleState(address(isModule), ModuleState.Deprecated);
        vm.expectRevert(ModuleManager.ModuleManager__WrongState.selector);
        moduleManager.changeModuleState(address(isModule), ModuleState.Enabled);
        vm.stopPrank();
    }

    function testChangeStateFromNonModuleReverts() public {
        vm.prank(moduleManagerOwner);
        vm.expectRevert(ModuleManager.ModuleManager__WrongState.selector);
        moduleManager.changeModuleState(address(isModule), ModuleState.Enabled);
    }

    /*//////////////////////////////////////////////////////////////
                               ADD MODULE
    //////////////////////////////////////////////////////////////*/

    function testAddModuleEmitsEvent() public {
        vm.prank(addressManager);
        vm.expectEmit(false, false, false, true, address(moduleManager));
        emit OnNewModule(address(isModule));
        moduleManager.addModule(address(isModule));

        ModuleState moduleState = moduleManager.getModuleState(address(isModule));

        assert(moduleState == ModuleState.Enabled);
    }

    /*//////////////////////////////////////////////////////////////
                              CHANGE STATE
    //////////////////////////////////////////////////////////////*/

    function testChangeModuleStateEmitsEvent() public addModule {
        assert(moduleManager.isActiveModule(address(isModule)));

        // From ENABLED to DISABLED
        vm.prank(moduleManagerOwner);
        vm.expectEmit(true, false, false, true, address(moduleManager));
        emit OnModuleStateChanged(address(isModule), ModuleState.Enabled, ModuleState.Disabled);
        moduleManager.changeModuleState(address(isModule), ModuleState.Disabled);

        assert(!moduleManager.isActiveModule(address(isModule)));

        // From DISABLED to PAUSED
        vm.prank(moduleManagerOwner);
        vm.expectEmit(true, false, false, true, address(moduleManager));
        emit OnModuleStateChanged(address(isModule), ModuleState.Disabled, ModuleState.Paused);
        moduleManager.changeModuleState(address(isModule), ModuleState.Paused);

        assert(!moduleManager.isActiveModule(address(isModule)));

        // From PAUSED to DISABLED
        vm.prank(moduleManagerOwner);
        vm.expectEmit(true, false, false, true, address(moduleManager));
        emit OnModuleStateChanged(address(isModule), ModuleState.Paused, ModuleState.Disabled);
        moduleManager.changeModuleState(address(isModule), ModuleState.Disabled);

        assert(!moduleManager.isActiveModule(address(isModule)));

        // From ENABLED to PAUSED
        vm.startPrank(moduleManagerOwner);
        moduleManager.changeModuleState(address(isModule), ModuleState.Enabled);
        vm.expectEmit(true, false, false, true, address(moduleManager));
        emit OnModuleStateChanged(address(isModule), ModuleState.Enabled, ModuleState.Paused);
        moduleManager.changeModuleState(address(isModule), ModuleState.Paused);
        vm.stopPrank();

        assert(!moduleManager.isActiveModule(address(isModule)));

        // DEPRECATED
        vm.prank(moduleManagerOwner);
        vm.expectEmit(true, false, false, true, address(moduleManager));
        emit OnModuleStateChanged(address(isModule), ModuleState.Paused, ModuleState.Deprecated);
        moduleManager.changeModuleState(address(isModule), ModuleState.Deprecated);

        assert(!moduleManager.isActiveModule(address(isModule)));
    }
}
