// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {IsModule, IsNotModule} from "test/mocks/ModuleMocks.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {ModuleState, ProtocolAddressType} from "contracts/types/TakasureTypes.sol";

contract ModuleManagerTest is Test {
    ModuleManager moduleManager;
    AddressManager addressManager;
    IsModule isModule;
    IsNotModule isNotModule;

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
        address addressManagerImplementation = address(new AddressManager());
        address addressManagerAddress = UnsafeUpgrades.deployUUPSProxy(
            addressManagerImplementation,
            abi.encodeCall(AddressManager.initialize, (msg.sender))
        );
        addressManager = AddressManager(addressManagerAddress);

        address moduleManagerImplementation = address(new ModuleManager());
        address moduleManagerAddress = UnsafeUpgrades.deployUUPSProxy(
            address(moduleManagerImplementation),
            abi.encodeCall(ModuleManager.initialize, (address(addressManager)))
        );
        moduleManager = ModuleManager(moduleManagerAddress);

        isModule = new IsModule();
        isNotModule = new IsNotModule();

        vm.startPrank(addressManager.owner());
        addressManager.addProtocolAddress(
            "MODULE_MANAGER",
            address(moduleManager),
            ProtocolAddressType.Protocol
        );

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    function testAddAddressZeroAsModuleReverts() public {
        vm.prank(address(addressManager));
        vm.expectRevert(ModuleManager.ModuleManager__AddressZeroNotAllowed.selector);
        moduleManager.addModule(address(0));
    }

    function testAddModuleTwiceReverts() public {
        vm.startPrank(address(addressManager));
        moduleManager.addModule(address(isModule));
        vm.expectRevert(ModuleManager.ModuleManager__AlreadyModule.selector);
        moduleManager.addModule(address(isModule));
        vm.stopPrank();
    }

    function testOnlyAddressManagerCanAddModules() public {
        address notAddressManager = makeAddr("notAddressManager");

        vm.prank(notAddressManager);
        vm.expectRevert();
        moduleManager.addModule(address(0));
    }

    function testAddContractIsNotModuleReverts() public {
        vm.prank(address(addressManager));
        vm.expectRevert(ModuleManager.ModuleManager__NotModule.selector);
        moduleManager.addModule(address(isNotModule));
    }

    modifier addModule() {
        vm.prank(address(addressManager));
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
        vm.startPrank(moduleManager.owner());
        moduleManager.changeModuleState(address(isModule), ModuleState.Deprecated);
        vm.expectRevert(ModuleManager.ModuleManager__WrongState.selector);
        moduleManager.changeModuleState(address(isModule), ModuleState.Enabled);
        vm.stopPrank();
    }

    function testChangeStateFromNonModuleReverts() public {
        vm.prank(moduleManager.owner());
        vm.expectRevert(ModuleManager.ModuleManager__WrongState.selector);
        moduleManager.changeModuleState(address(isModule), ModuleState.Enabled);
    }

    /*//////////////////////////////////////////////////////////////
                               ADD MODULE
    //////////////////////////////////////////////////////////////*/

    function testAddModuleEmitsEvent() public {
        vm.prank(address(addressManager));
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
        vm.prank(moduleManager.owner());
        vm.expectEmit(true, false, false, true, address(moduleManager));
        emit OnModuleStateChanged(address(isModule), ModuleState.Enabled, ModuleState.Disabled);
        moduleManager.changeModuleState(address(isModule), ModuleState.Disabled);

        assert(!moduleManager.isActiveModule(address(isModule)));

        // From DISABLED to PAUSED
        vm.prank(moduleManager.owner());
        vm.expectEmit(true, false, false, true, address(moduleManager));
        emit OnModuleStateChanged(address(isModule), ModuleState.Disabled, ModuleState.Paused);
        moduleManager.changeModuleState(address(isModule), ModuleState.Paused);

        assert(!moduleManager.isActiveModule(address(isModule)));

        // From PAUSED to DISABLED
        vm.prank(moduleManager.owner());
        vm.expectEmit(true, false, false, true, address(moduleManager));
        emit OnModuleStateChanged(address(isModule), ModuleState.Paused, ModuleState.Disabled);
        moduleManager.changeModuleState(address(isModule), ModuleState.Disabled);

        assert(!moduleManager.isActiveModule(address(isModule)));

        // From ENABLED to PAUSED
        vm.startPrank(moduleManager.owner());
        moduleManager.changeModuleState(address(isModule), ModuleState.Enabled);
        vm.expectEmit(true, false, false, true, address(moduleManager));
        emit OnModuleStateChanged(address(isModule), ModuleState.Enabled, ModuleState.Paused);
        moduleManager.changeModuleState(address(isModule), ModuleState.Paused);
        vm.stopPrank();

        assert(!moduleManager.isActiveModule(address(isModule)));

        // DEPRECATED
        vm.prank(moduleManager.owner());
        vm.expectEmit(true, false, false, true, address(moduleManager));
        emit OnModuleStateChanged(address(isModule), ModuleState.Paused, ModuleState.Deprecated);
        moduleManager.changeModuleState(address(isModule), ModuleState.Deprecated);

        assert(!moduleManager.isActiveModule(address(isModule)));
    }
}
