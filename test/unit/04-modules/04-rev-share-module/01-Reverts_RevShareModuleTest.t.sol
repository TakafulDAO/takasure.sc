// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ModuleState, ProtocolAddressType} from "contracts/types/TakasureTypes.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";

contract Reverts_RevShareModuleTest is Test {
    TestDeployProtocol deployer;
    RevShareModule revShareModule;
    HelperConfig helperConfig;
    IUSDC usdc;
    address module = makeAddr("module");
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
        usdc = IUSDC(addressManager.getProtocolAddressByName("CONTRIBUTION_TOKEN").addr);

        vm.prank(addressManager.owner());
        addressManager.addProtocolAddress("RANDOM_MODULE", module, ProtocolAddressType.Module);
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
