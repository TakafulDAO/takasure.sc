// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ModuleState} from "contracts/types/TakasureTypes.sol";

contract RevShareModuleFuzzTest is Test {
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

    function testSetContractStateRevertsIfCallerIsWrong(address caller) public {
        vm.assume(caller != moduleManagerAddress);

        vm.prank(caller);
        vm.expectRevert();
        revShareModule.setContractState(ModuleState.Paused);
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

    function testSetDistributionsActiveRevertsIfCallerIsInvalid(address caller) public {
        vm.assume(caller != takadao);

        vm.prank(caller);
        vm.expectRevert();
        revShareModule.setDistributionsActive(false, block.timestamp + 1 days);
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
}
