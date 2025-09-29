// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, StdInvariant, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {SubscriptionModuleHandler} from "test/helpers/handlers/SubscriptionModuleHandler.t.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {AssociationMember, AssociationMemberState} from "contracts/types/TakasureTypes.sol";

contract SubscriptionInvariantTest is StdInvariant, Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;
    SubscriptionModule subscriptionModule;
    SubscriptionModuleHandler handler;
    address takadao;
    address couponRedeemer;
    IUSDC usdc;

    uint256 private lastMemberCounter;

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        addressesAndRoles = new AddAddressesAndRoles();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addressManager,
            ModuleManager moduleManager
        ) = managersDeployer.run();
        (address operator, , , address redeemer, , , ) = addressesAndRoles.run(
            addressManager,
            config,
            address(moduleManager)
        );
        (, , , , , , , subscriptionModule) = moduleDeployer.run(addressManager);

        takadao = operator;
        couponRedeemer = redeemer;
        usdc = IUSDC(config.contributionToken);

        handler = new SubscriptionModuleHandler(subscriptionModule, usdc, takadao);

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = SubscriptionModuleHandler.paySubscription.selector;
        selectors[1] = SubscriptionModuleHandler.refund.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));

        uint256 memberIdCounterSlot = 2;
        bytes32 memberIdCounterSlotBytes = vm.load(
            address(subscriptionModule),
            bytes32(uint256(memberIdCounterSlot))
        );
        lastMemberCounter = uint256(memberIdCounterSlotBytes);
    }

    // Invariant 1: memberIdCounter never decreases
    function invariant_memberIdCounterNonDecreasing() public {
        uint256 memberIdCounterSlot = 2;
        bytes32 memberIdCounterSlotBytes = vm.load(
            address(subscriptionModule),
            bytes32(uint256(memberIdCounterSlot))
        );
        uint256 currentCounter = uint256(memberIdCounterSlotBytes);

        assertGe(currentCounter, lastMemberCounter);
        lastMemberCounter = currentCounter;
    }

    // Invariant 2: No refunded member is active
    function invariant_noRefundedMemberActive() public view {
        for (uint256 i = 0; i < handler.usersLength(); i++) {
            address user = handler.usersAt(i);
            AssociationMember memory userAsMember = subscriptionModule.getAssociationMember(user);
            if (userAsMember.isRefunded) {
                assert(userAsMember.memberState == AssociationMemberState.Inactive);
            }
        }
    }

    // Invariant 3: Contract balance <= sum of active contributions
    function invariant_balanceCheck() public view {
        uint256 bal = usdc.balanceOf(address(subscriptionModule));
        uint256 expectedBalance = handler.countActiveMembers() * 25e6;
        assertLe(bal, expectedBalance);
    }
}
