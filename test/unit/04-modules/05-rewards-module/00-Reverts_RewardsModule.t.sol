// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {ReferralRewardsModule} from "contracts/modules/ReferralRewardsModule.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {AssociationMemberState, ModuleState} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract Reverts_ReferralRewardsModule is Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;

    ReferralRewardsModule referralRewardsModule;
    AddressManager addressManager;
    ModuleManager moduleManager;

    address operator;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        addressesAndRoles = new AddAddressesAndRoles();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addrMgr,
            ModuleManager modMgr
        ) = managersDeployer.run();

        (address operatorAddr, , , , , ) = addressesAndRoles.run(addrMgr, config, address(modMgr));

        (, , , , referralRewardsModule, , ) = moduleDeployer.run(addrMgr);

        addressManager = addrMgr;
        moduleManager = modMgr;
        operator = operatorAddr;
    }

    function testRewardsModule_calculateReferralRewardsRevertIfNotCalledByAModule() public {
        vm.expectRevert(ModuleErrors.Module__NotAuthorizedCaller.selector);
        referralRewardsModule.calculateReferralRewards(25e6, 25e6, alice, bob, 0);
    }

    function testRewardsModule_rewardParentsRevertIfNotCalledByAModule() public {
        vm.expectRevert(ModuleErrors.Module__NotAuthorizedCaller.selector);
        referralRewardsModule.rewardParents(alice);
    }
}
