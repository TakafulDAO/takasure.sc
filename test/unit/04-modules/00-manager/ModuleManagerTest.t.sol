// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ModuleManager} from "contracts/takasure/modules/manager/ModuleManager.sol";
import {IsModule, IsNotModule} from "test/mocks/ModuleMocks.sol";

contract ModuleManagerTest is Test {
    ModuleManager moduleManager;
    IsModule isModule;
    IsNotModule isNotModule;

    address moduleManagerOwner = makeAddr("moduleManagerOwner");

    enum State {
        DISABLED,
        ENABLED,
        PAUSED,
        DEPRECATED
    }

    event OnNewModule(address newModuleAddr, State newModuleStatus);
    event OnModuleStateChanged(State oldState, State newState);

    function setUp() public {
        vm.prank(moduleManagerOwner);

        moduleManager = new ModuleManager();
        isModule = new IsModule();
        isNotModule = new IsNotModule();
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    function testAddModuleAtPausedStateReverts() public {
        vm.prank(moduleManagerOwner);
        vm.expectRevert(ModuleManager.ModuleManager__WrongInitialState.selector);
        moduleManager.addModule(address(isModule), ModuleManager.State.PAUSED);

        assert(!moduleManager.isModule(address(isModule)));
    }

    function testAddModuleAtDeprecatedStateReverts() public {
        vm.prank(moduleManagerOwner);
        vm.expectRevert(ModuleManager.ModuleManager__WrongInitialState.selector);
        moduleManager.addModule(address(isModule), ModuleManager.State.DEPRECATED);

        assert(!moduleManager.isModule(address(isModule)));
    }

    function testAddAddressZeroAsModuleReverts() public {
        vm.prank(moduleManagerOwner);
        vm.expectRevert(ModuleManager.ModuleManager__AddressZeroNotAllowed.selector);
        moduleManager.addModule(address(0), ModuleManager.State.ENABLED);
    }

    function testAddModuleTwiceReverts() public {
        vm.startPrank(moduleManagerOwner);
        moduleManager.addModule(address(isModule), ModuleManager.State.ENABLED);
        vm.expectRevert(ModuleManager.ModuleManager__AlreadyModule.selector);
        moduleManager.addModule(address(isModule), ModuleManager.State.ENABLED);
        vm.stopPrank();
    }

    function testOnlyOwnerCanAddModules() public {
        address notOwner = makeAddr("notOwner");

        vm.prank(notOwner);
        vm.expectRevert();
        moduleManager.addModule(address(0), ModuleManager.State.ENABLED);
    }

    function testAddContractIsNotModuleReverts() public {
        vm.prank(moduleManagerOwner);
        vm.expectRevert(ModuleManager.ModuleManager__NotModule.selector);
        moduleManager.addModule(address(isNotModule), ModuleManager.State.ENABLED);
    }

    modifier addModule() {
        vm.prank(moduleManagerOwner);
        moduleManager.addModule(address(isModule), ModuleManager.State.DISABLED);
        _;
    }

    function testOnlyOwnerCanChangeModuleState() public addModule {
        address notOwner = makeAddr("notOwner");

        vm.prank(notOwner);
        vm.expectRevert();
        moduleManager.changeModuleStatus(address(isModule), ModuleManager.State.ENABLED);
    }

    function testChangeStateFromDeprecatedReverts() public addModule {
        vm.startPrank(moduleManagerOwner);
        moduleManager.changeModuleStatus(address(isModule), ModuleManager.State.DEPRECATED);
        vm.expectRevert(ModuleManager.ModuleManager__WrongState.selector);
        moduleManager.changeModuleStatus(address(isModule), ModuleManager.State.ENABLED);
        vm.stopPrank();
    }

    function testChangeStateFromNonModuleReverts() public {
        vm.prank(moduleManagerOwner);
        vm.expectRevert(ModuleManager.ModuleManager__NotModule.selector);
        moduleManager.changeModuleStatus(address(isModule), ModuleManager.State.ENABLED);
    }

    /*//////////////////////////////////////////////////////////////
                               ADD MODULE
    //////////////////////////////////////////////////////////////*/

    function testAddModuleAtDisabledStateEmitsEvent() public {
        vm.prank(moduleManagerOwner);
        vm.expectEmit(false, false, false, true, address(moduleManager));
        emit OnNewModule(address(isModule), State.DISABLED);
        moduleManager.addModule(address(isModule), ModuleManager.State.DISABLED);

        ModuleManager.State moduleState = moduleManager.getModuleState(address(isModule));

        assert(moduleState == ModuleManager.State.DISABLED);
    }

    function testAddModuleAtEnabledStateEmitsEvent() public {
        vm.prank(moduleManagerOwner);
        vm.expectEmit(false, false, false, true, address(moduleManager));
        emit OnNewModule(address(isModule), State.ENABLED);
        moduleManager.addModule(address(isModule), ModuleManager.State.ENABLED);

        ModuleManager.State moduleState = moduleManager.getModuleState(address(isModule));

        assert(moduleState == ModuleManager.State.ENABLED);
    }

    /*//////////////////////////////////////////////////////////////
                              CHANGE STATE
    //////////////////////////////////////////////////////////////*/

    function testChangeModuleStateEmitsEvent() public addModule {
        assert(!moduleManager.isModule(address(isModule)));

        // From DISABLED to ENABLED
        vm.prank(moduleManagerOwner);
        vm.expectEmit(false, false, false, true, address(moduleManager));
        emit OnModuleStateChanged(State.DISABLED, State.ENABLED);
        moduleManager.changeModuleStatus(address(isModule), ModuleManager.State.ENABLED);

        assert(moduleManager.isModule(address(isModule)));

        // From ENABLED to DISABLED
        vm.prank(moduleManagerOwner);
        vm.expectEmit(false, false, false, true, address(moduleManager));
        emit OnModuleStateChanged(State.ENABLED, State.DISABLED);
        moduleManager.changeModuleStatus(address(isModule), ModuleManager.State.DISABLED);

        assert(!moduleManager.isModule(address(isModule)));

        // From DISABLED to PAUSED
        vm.prank(moduleManagerOwner);
        vm.expectEmit(false, false, false, true, address(moduleManager));
        emit OnModuleStateChanged(State.DISABLED, State.PAUSED);
        moduleManager.changeModuleStatus(address(isModule), ModuleManager.State.PAUSED);

        assert(!moduleManager.isModule(address(isModule)));

        // From PAUSED to DISABLED
        vm.prank(moduleManagerOwner);
        vm.expectEmit(false, false, false, true, address(moduleManager));
        emit OnModuleStateChanged(State.PAUSED, State.DISABLED);
        moduleManager.changeModuleStatus(address(isModule), ModuleManager.State.DISABLED);

        assert(!moduleManager.isModule(address(isModule)));

        // From ENABLED to PAUSED
        vm.startPrank(moduleManagerOwner);
        moduleManager.changeModuleStatus(address(isModule), ModuleManager.State.ENABLED);
        vm.expectEmit(false, false, false, true, address(moduleManager));
        emit OnModuleStateChanged(State.ENABLED, State.PAUSED);
        moduleManager.changeModuleStatus(address(isModule), ModuleManager.State.PAUSED);
        vm.stopPrank();

        assert(!moduleManager.isModule(address(isModule)));

        // DEPRECATED
        vm.prank(moduleManagerOwner);
        vm.expectEmit(false, false, false, true, address(moduleManager));
        emit OnModuleStateChanged(State.PAUSED, State.DEPRECATED);
        moduleManager.changeModuleStatus(address(isModule), ModuleManager.State.DEPRECATED);

        assert(!moduleManager.isModule(address(isModule)));
    }
}
