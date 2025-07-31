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
import {MemberModule} from "contracts/modules/MemberModule.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {AssociationMemberState, ModuleState} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract Reverts_MemberModule is Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;

    KYCModule kycModule;
    MemberModule memberModule;
    SubscriptionModule subscriptionModule;
    AddressManager addressManager;
    ModuleManager moduleManager;
    IUSDC usdc;

    address operator;
    address kycProvider;
    address couponRedeemer;
    address alice = makeAddr("alice");

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        addressesAndRoles = new AddAddressesAndRoles();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addrMgr,
            ModuleManager modMgr
        ) = managersDeployer.run();

        (address operatorAddr, , address kyc, address redeemer, , ) = addressesAndRoles.run(
            addrMgr,
            config,
            address(modMgr)
        );

        (, , kycModule, memberModule, , , subscriptionModule) = moduleDeployer.run(addrMgr);

        addressManager = addrMgr;
        moduleManager = modMgr;
        kycProvider = kyc;
        operator = operatorAddr;
        couponRedeemer = redeemer;

        usdc = IUSDC(config.contributionToken);

        deal(address(usdc), alice, 25e6);

        vm.prank(alice);
        usdc.approve(address(subscriptionModule), 25e6);

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(alice, address(0), 0, block.timestamp);

        vm.prank(kycProvider);
        kycModule.approveKYC(alice);
    }

    modifier travelInTime() {
        vm.warp(block.timestamp + 366 days);
        vm.roll(block.number + 1);
        _;
    }

    function testMemberModule_payRecurringAssociationSubscriptionRevertIfModuleDisabled()
        public
        travelInTime
    {
        vm.prank(address(moduleManager));
        memberModule.setContractState(ModuleState.Paused);

        vm.prank(alice);
        vm.expectRevert();
        memberModule.payRecurringAssociationSubscription(alice);
    }

    function testMemberModule_cancelRevertIfModuleDisabled() public travelInTime {
        vm.prank(address(moduleManager));
        memberModule.setContractState(ModuleState.Paused);

        vm.prank(alice);
        vm.expectRevert();
        memberModule.cancelAssociationSubscription(alice);
    }

    function testMemberModule_payRecurringAssociationSubscriptionRevertIfTooEarly() public {
        vm.prank(alice);
        vm.expectRevert(MemberModule.MemberModule__InvalidDate.selector);
        memberModule.payRecurringAssociationSubscription(alice);
    }

    function testMemberModule_payRecurringAssociationSubscriptionRevertIfTooLate() public {
        vm.warp(block.timestamp + 396 days);
        vm.roll(block.number + 1);

        vm.prank(alice);
        vm.expectRevert(MemberModule.MemberModule__InvalidDate.selector);
        memberModule.payRecurringAssociationSubscription(alice);
    }

    function testMemberModule_payRecurringAssociationSubscriptionRevertIfIsNoActive() public {
        vm.prank(operator);
        subscriptionModule.refund(alice);

        vm.warp(block.timestamp + 366 days);
        vm.roll(block.number + 1);

        vm.prank(alice);
        vm.expectRevert(ModuleErrors.Module__WrongMemberState.selector);
        memberModule.payRecurringAssociationSubscription(alice);
    }

    function testMemberModule_cancelAssociationSubscriptionRevertIfTooEarly() public {
        vm.expectRevert(MemberModule.MemberModule__InvalidDate.selector);
        memberModule.cancelAssociationSubscription(alice);
    }

    function testMemberModule_cancelAssociationSubscriptionRevertIfIsNoActive() public {
        vm.prank(operator);
        subscriptionModule.refund(alice);

        vm.warp(block.timestamp + 396 days);
        vm.roll(block.number + 1);

        vm.prank(alice);
        vm.expectRevert(ModuleErrors.Module__WrongMemberState.selector);
        memberModule.cancelAssociationSubscription(alice);
    }
}
