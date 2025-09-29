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
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {AssociationMemberState, ModuleState} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract Reverts_KYCModule is Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;

    KYCModule kycModule;
    SubscriptionModule subscriptionModule;
    AddressManager addressManager;
    ModuleManager moduleManager;
    IUSDC usdc;

    address operator;
    address kycProvider;
    address couponRedeemer;
    address alice = makeAddr("alice");
    address unauthorizedUser = makeAddr("unauthorized");

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        addressesAndRoles = new AddAddressesAndRoles();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addrMgr,
            ModuleManager modMgr
        ) = managersDeployer.run();

        (address operatorAddr, , address kyc, address redeemer, , , ) = addressesAndRoles.run(
            addrMgr,
            config,
            address(modMgr)
        );

        (, , kycModule, , , , , subscriptionModule) = moduleDeployer.run(addrMgr);

        addressManager = addrMgr;
        moduleManager = modMgr;
        kycProvider = kyc;
        operator = operatorAddr;
        couponRedeemer = redeemer;

        usdc = IUSDC(config.contributionToken);

        deal(address(usdc), alice, 25e6);

        vm.prank(alice);
        usdc.approve(address(subscriptionModule), 25e6);
    }

    // function testKYCModule_ApproveKYCRevertIfModuleDisabled() public {
    //     vm.prank(address(moduleManager));
    //     kycModule.setContractState(ModuleState.Paused);

    //     vm.prank(kycProvider);
    //     vm.expectRevert();
    //     kycModule.approveKYC(alice);
    // }

    function testKYCModule_ApproveKYCRevertIfZeroAddress() public {
        vm.prank(kycProvider);
        vm.expectRevert();
        kycModule.approveKYC(address(0));
    }

    function testKYCModule_ApproveKYCRevertIfAlreadyKYCed() public {
        // First approval should succeed
        vm.startPrank(kycProvider);
        kycModule.approveKYC(alice);

        // Second approval should revert
        vm.expectRevert(KYCModule.KYCModule__MemberAlreadyKYCed.selector);
        kycModule.approveKYC(alice);
        vm.stopPrank();
    }

    function testKYCModule_ApproveKYCRevertIfUserIsRefunded() public {
        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(alice, address(0), 0, block.timestamp);

        vm.prank(operator);
        subscriptionModule.refund(alice);

        vm.prank(kycProvider);
        vm.expectRevert(KYCModule.KYCModule__ContributionRequired.selector);
        kycModule.approveKYC(alice);
    }
}
