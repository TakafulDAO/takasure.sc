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
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {AssociationMemberState, ModuleState} from "contracts/types/TakasureTypes.sol";

contract KYCModule_UnitTest is Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;

    KYCModule kycModule;
    AddressManager addressManager;
    ModuleManager moduleManager;

    address operator;
    address kycProvider;
    address unauthorizedUser;
    address testUser;

    event OnMemberKycVerified(uint256 indexed memberId, address indexed member);

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        addressesAndRoles = new AddAddressesAndRoles();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addrMgr,
            ModuleManager modMgr
        ) = managersDeployer.run();

        (address operatorAddr, , address kyc, , , ) = addressesAndRoles.run(
            addrMgr,
            config,
            address(modMgr)
        );

        (, , kycModule, , , , ) = moduleDeployer.run(addrMgr);

        addressManager = addrMgr;
        moduleManager = modMgr;
        kycProvider = kyc;
        operator = operatorAddr;

        unauthorizedUser = makeAddr("unauthorized");
        testUser = makeAddr("testUser");
    }

    function testApproveKYC_ApprovesKYCUpdatesMapping() public {
        vm.prank(kycProvider);
        kycModule.approveKYC(testUser);

        assert(kycModule.isKYCed(testUser));
    }

    function testApproveKYC_ApprovesKYCEmitsEvent() public {
        vm.prank(kycProvider);
        vm.expectEmit(true, true, false, false, address(kycModule));
        emit OnMemberKycVerified(0, testUser);
        kycModule.approveKYC(testUser);
    }
}
