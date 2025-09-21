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
import {AssociationMemberState, ModuleState, AssociationMember} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract Cancel_MemberModule is Test {
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

    event OnMemberCanceled(uint256 indexed memberId, address indexed member);

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

        vm.warp(block.timestamp + 396 days);
        vm.roll(block.number + 1);
    }

    function testMemberModule_cancelAssociationSubscriptionUpdatesMember() public {
        AssociationMember memory aliceAsMember = subscriptionModule.getAssociationMember(alice);

        assertEq(aliceAsMember.memberId, 1);
        assertGt(aliceAsMember.associateStartTime, 0);
        assertEq(aliceAsMember.wallet, alice);
        assert(aliceAsMember.memberState == AssociationMemberState.Active);

        memberModule.cancelAssociationSubscription(alice);

        aliceAsMember = subscriptionModule.getAssociationMember(alice);

        assertEq(aliceAsMember.memberId, 1);
        assertEq(aliceAsMember.associateStartTime, 0);
        assertEq(aliceAsMember.wallet, alice);
        assert(aliceAsMember.memberState == AssociationMemberState.Canceled);
    }

    function testMemberModule_payRecurringAssociationSubscriptionEmitsEvent() public {
        vm.expectEmit(true, true, false, false, address(memberModule));
        emit OnMemberCanceled(1, alice);
        memberModule.cancelAssociationSubscription(alice);
    }
}
