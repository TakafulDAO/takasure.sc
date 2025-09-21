// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {KYCModule} from "contracts/modules/KYCModule.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {AssociationMemberState, ModuleState, AssociationMember} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ApproveKYC_KYCModule is Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;

    SubscriptionModule subscriptionModule;
    KYCModule kycModule;
    AddressManager addressManager;
    ModuleManager moduleManager;

    address operator;
    address kycProvider;
    address couponRedeemer;
    IUSDC usdc;
    address unauthorizedUser = makeAddr("unauthorized");
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 150e6; // 150 USDC

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

        (address operatorAddr, , address kyc, address redeemer, , ) = addressesAndRoles.run(
            addrMgr,
            config,
            address(modMgr)
        );

        (, , kycModule, , , , subscriptionModule) = moduleDeployer.run(addrMgr);

        addressManager = addrMgr;
        moduleManager = modMgr;
        kycProvider = kyc;
        operator = operatorAddr;
        couponRedeemer = redeemer;

        usdc = IUSDC(config.contributionToken);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.prank(alice);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
    }

    function testKYCModule_ApprovesKYCUpdatesAssociationMember() public {
        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(alice, address(0), 0, block.timestamp);

        AssociationMember memory aliceAsMember = subscriptionModule.getAssociationMember(alice);
        assert(aliceAsMember.memberState == AssociationMemberState.Inactive);

        vm.prank(kycProvider);
        kycModule.approveKYC(alice);

        aliceAsMember = subscriptionModule.getAssociationMember(alice);

        assert(aliceAsMember.memberState == AssociationMemberState.Active);
        assert(kycModule.isKYCed(alice));
    }

    function testKYCModule_ApprovesKYCUpdatesMapping() public {
        vm.prank(kycProvider);
        kycModule.approveKYC(alice);

        assert(kycModule.isKYCed(alice));
    }

    function testKYCModule_ApproveKYCEmitsEventOnKYCApproval() public {
        vm.prank(kycProvider);
        vm.expectEmit(true, true, false, false, address(kycModule));
        emit OnMemberKycVerified(0, alice);
        kycModule.approveKYC(alice);
    }
}
