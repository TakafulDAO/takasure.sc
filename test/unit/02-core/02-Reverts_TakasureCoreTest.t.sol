// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployReserve} from "test/utils/02-DeployReserve.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";

contract Reverts_TakasureCoreTest is StdCheats, Test {
    DeployManagers managersDeployer;
    AddAddressesAndRoles addressesAndRoles;
    DeployReserve deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    address takadao;
    address public alice = makeAddr("alice");

    function setUp() public {
        managersDeployer = new DeployManagers();
        addressesAndRoles = new AddAddressesAndRoles();
        deployer = new DeployReserve();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addressManager,
            ModuleManager moduleManager
        ) = managersDeployer.run();
        (address operator, , , , , , ) = addressesAndRoles.run(
            addressManager,
            config,
            address(moduleManager)
        );
        takasureReserve = deployer.run(config, addressManager);

        takadao = operator;
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/
    /// @dev `setNewServiceFee` must revert if the caller is not the admin
    function testTakasureCore_setNewServiceFeeMustRevertIfTheCallerIsNotTheAdmin() public {
        uint8 newServiceFee = 50;
        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setNewServiceFee(newServiceFee);
    }

    /// @dev `setNewServiceFee` must revert if it is higher than 35
    function testTakasureCore_setNewServiceFeeMustRevertIfHigherThan35() public {
        uint8 newServiceFee = 36;
        vm.prank(takadao);
        vm.expectRevert(TakasureReserve.TakasureReserve__WrongValue.selector);
        takasureReserve.setNewServiceFee(newServiceFee);
    }

    /// @dev `setNewMinimumThreshold` must revert if the caller is not the admin
    function testTakasureCore_setNewMinimumThresholdMustRevertIfTheCallerIsNotTheAdmin() public {
        uint8 newThreshold = 50;
        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setNewMinimumThreshold(newThreshold);
    }

    /// @dev `setAllowCustomDuration` must revert if the caller is not the admin
    function testTakasureCore_setAllowCustomDurationMustRevertIfTheCallerIsNotTheAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setAllowCustomDuration(true);
    }
}
