// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {KYCModule} from "contracts/modules/KYCModule.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {ModuleState} from "contracts/types/TakasureTypes.sol";

contract KYCModuleFuzzTest is StdCheats, Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;
    KYCModule kycModule;
    address takadao;
    address kycProvider;
    address moduleManagerAddress;
    address public alice = makeAddr("alice");

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        addressesAndRoles = new AddAddressesAndRoles();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addressManager,
            ModuleManager moduleManager
        ) = managersDeployer.run();
        (address operator, , address kyc, , , ) = addressesAndRoles.run(
            addressManager,
            config,
            address(moduleManager)
        );
        (, , kycModule, , , , ) = moduleDeployer.run(addressManager);

        takadao = operator;
        kycProvider = kyc;
        moduleManagerAddress = address(moduleManager);
    }

    function testSetContractStateRevertsIfCallerIsWrong(address caller) public {
        vm.assume(caller != moduleManagerAddress);

        vm.prank(caller);
        vm.expectRevert();
        kycModule.setContractState(ModuleState.Paused);
    }

    function testApproveKYCRevertsIfCallerIsWrong(address caller) public {
        vm.assume(caller != kycProvider);

        vm.prank(caller);
        vm.expectRevert();
        kycModule.approveKYC(alice);
    }

    function testUpgradeRevertsIfCallerIsInvalid(address caller) public {
        vm.assume(caller != takadao);
        address newImpl = makeAddr("newImpl");

        vm.prank(caller);
        vm.expectRevert();
        kycModule.upgradeToAndCall(newImpl, "");
    }
}
