// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ModuleState} from "contracts/types/TakasureTypes.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";

contract Reverts_RevShareModuleTest is Test {
    TestDeployProtocol deployer;
    RevShareModule revShareModule;
    HelperConfig helperConfig;
    address takadao;
    address revShareModuleAddress;
    address moduleManagerAddress;

    function setUp() public {
        deployer = new TestDeployProtocol();
        (, , , , , , revShareModuleAddress, , , , helperConfig) = deployer.run();

        revShareModule = RevShareModule(revShareModuleAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        takadao = config.takadaoOperator;

        uint256 addressManagerAddressSlot = 0;
        bytes32 addressManagerAddressSlotBytes = vm.load(
            address(revShareModule),
            bytes32(uint256(addressManagerAddressSlot))
        );
        AddressManager addressManager = AddressManager(
            address(uint160(uint256(addressManagerAddressSlotBytes)))
        );

        moduleManagerAddress = addressManager.getProtocolAddressByName("MODULE_MANAGER").addr;
    }

    function testRevShareModule_setAvailableDateRevertsIfModuleIsNotEnabled() public {
        vm.prank(moduleManagerAddress);
        revShareModule.setContractState(ModuleState.Paused);

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
        vm.prank(moduleManagerAddress);
        revShareModule.setContractState(ModuleState.Paused);

        vm.prank(takadao);
        vm.expectRevert(ModuleErrors.Module__WrongModuleState.selector);
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
        vm.prank(moduleManagerAddress);
        revShareModule.setContractState(ModuleState.Paused);

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
        vm.prank(moduleManagerAddress);
        revShareModule.setContractState(ModuleState.Paused);

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
}
