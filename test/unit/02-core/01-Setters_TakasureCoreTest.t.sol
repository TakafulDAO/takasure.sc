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
import {BenefitMember, Reserve, CashFlowVars} from "contracts/types/TakasureTypes.sol";

contract Setters_TakasureCoreTest is StdCheats, Test {
    DeployManagers managersDeployer;
    DeployReserve deployer;
    AddAddressesAndRoles addressesAndRoles;
    TakasureReserve takasureReserve;
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

    /// @dev Test the owner can set a new service fee
    function testTakasureReserve_setNewServiceFeeToNewValue() public {
        assert(2 + 2 == 4);
        uint8 newServiceFee = 35;

        vm.prank(takadao);
        vm.expectEmit(true, false, false, false, address(takasureReserve));
        emit TakasureEvents.OnServiceFeeChanged(newServiceFee);
        takasureReserve.setNewServiceFee(newServiceFee);

        uint8 serviceFee = takasureReserve.getReserveValues().serviceFee;

        assertEq(newServiceFee, serviceFee);
    }

    /// @dev Test the owner can set a new minimum threshold
    function testTakasureCore_setNewMinimumThreshold() public {
        uint256 newMinimumThreshold = 50e6;

        vm.prank(takadao);
        vm.expectEmit(true, false, false, false, address(takasureReserve));
        emit TakasureEvents.OnNewMinimumThreshold(newMinimumThreshold);
        takasureReserve.setNewMinimumThreshold(newMinimumThreshold);

        assertEq(newMinimumThreshold, takasureReserve.getReserveValues().minimumThreshold);
    }

    /// @dev Test the owner can set a new minimum threshold
    function testTakasureCore_setNewMaximumThreshold() public {
        uint256 newMaximumThreshold = 50e6;

        vm.prank(takadao);
        vm.expectEmit(true, false, false, false, address(takasureReserve));
        emit TakasureEvents.OnNewMaximumThreshold(newMaximumThreshold);
        takasureReserve.setNewMaximumThreshold(newMaximumThreshold);

        assertEq(newMaximumThreshold, takasureReserve.getReserveValues().maximumThreshold);
    }

    /// @dev Test the owner can set custom duration
    function testTakasureCore_setAllowCustomDuration() public {
        vm.prank(takadao);
        takasureReserve.setAllowCustomDuration(true);

        assertEq(true, takasureReserve.getReserveValues().allowCustomDuration);
    }

    function testTakasureCore_setAddressManagerContract() public {
        vm.prank(takadao);
        takasureReserve.setAddressManagerContract(alice);

        assertEq(alice, address(takasureReserve.addressManager()));

        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setAddressManagerContract(takadao);
    }

    function testTakasureCore_onlyModuleFunctions() public {
        BenefitMember memory member;
        Reserve memory reserve;
        CashFlowVars memory cashFlowVars;

        vm.startPrank(takadao);
        vm.expectRevert(TakasureReserve.TakasureReserve__UnallowedAccess.selector);
        takasureReserve.setMemberValuesFromModule(member);

        vm.expectRevert(TakasureReserve.TakasureReserve__UnallowedAccess.selector);
        takasureReserve.setReserveValuesFromModule(reserve);

        vm.expectRevert(TakasureReserve.TakasureReserve__UnallowedAccess.selector);
        takasureReserve.setCashFlowValuesFromModule(cashFlowVars);

        vm.expectRevert(TakasureReserve.TakasureReserve__UnallowedAccess.selector);
        takasureReserve.setMonthToCashFlowValuesFromModule(0, 0);

        vm.expectRevert(TakasureReserve.TakasureReserve__UnallowedAccess.selector);
        takasureReserve.setDayToCashFlowValuesFromModule(0, 0, 0);

        vm.expectRevert(TakasureReserve.TakasureReserve__UnallowedAccess.selector);
        takasureReserve.memberSurplus(member);
        vm.stopPrank();
    }

    function testTakasureCore_setNewFundMarketExpendsShare() public {
        vm.prank(takadao);
        takasureReserve.setNewFundMarketExpendsShare(10);

        vm.prank(takadao);
        vm.expectRevert(TakasureReserve.TakasureReserve__WrongValue.selector);
        takasureReserve.setNewFundMarketExpendsShare(36);

        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setNewFundMarketExpendsShare(10);
    }
}
