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
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {ModuleState} from "contracts/types/TakasureTypes.sol";

contract SubscriptionModuleFuzzTest is StdCheats, Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;
    SubscriptionModule subscriptionModule;
    address takadao;
    address couponRedeemer;
    address moduleManagerAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 150e6; // 150 USDC

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        addressesAndRoles = new AddAddressesAndRoles();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addressManager,
            ModuleManager moduleManager
        ) = managersDeployer.run();
        (address operator, , , address redeemer, , ) = addressesAndRoles.run(
            addressManager,
            config,
            address(moduleManager)
        );
        (, , , , , , subscriptionModule) = moduleDeployer.run(addressManager);

        takadao = operator;
        couponRedeemer = redeemer;
        moduleManagerAddress = address(moduleManager);

        usdc = IUSDC(config.contributionToken);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.prank(alice);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
    }

    function testSetContractStateRevertsIfCallerIsWrong(address caller) public {
        vm.assume(caller != moduleManagerAddress);

        vm.prank(caller);
        vm.expectRevert();
        subscriptionModule.setContractState(ModuleState.Paused);
    }

    function testPaySubscriptionOnBehalfOfRevertsIfCallerIsWrong(address caller) public {
        vm.assume(caller != couponRedeemer);

        vm.prank(caller);
        vm.expectRevert();
        subscriptionModule.paySubscriptionOnBehalfOf(alice, address(0), 0, block.timestamp);
    }

    function testPaySubscriptionOnBehalfOfRevertsIfCouponIsInvalid(uint256 coupon) public {
        vm.assume(coupon != 0);
        vm.assume(coupon != 25e6);

        vm.prank(couponRedeemer);
        vm.expectRevert();
        subscriptionModule.paySubscriptionOnBehalfOf(alice, address(0), coupon, block.timestamp);
    }
}
