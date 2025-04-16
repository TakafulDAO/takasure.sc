// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";

contract Reverts_TakasureCoreTest is StdCheats, Test {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    address takasureReserveProxy;
    address admin;
    address takadao;
    address public alice = makeAddr("alice");

    function setUp() public {
        deployer = new TestDeployProtocol();
        (, bmConsumerMock, takasureReserveProxy, , , , , , , , helperConfig) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        takadao = config.takadaoOperator;

        takasureReserve = TakasureReserve(takasureReserveProxy);

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/
    /// @dev `setNewServiceFee` must revert if the caller is not the admin
    function testTakasureCore_setNewServiceFeeMustRevertIfTheCallerIsNotTheAdmin() public {
        uint8 newServiceFee = 50;
        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setNewServiceFee(newServiceFee);
    }

    /// @dev `setNewServiceFee` must revert if it is higher than 35
    function testTakasureCore_setNewServiceFeeMustRevertIfHigherThan35() public {
        uint8 newServiceFee = 36;
        vm.prank(admin);
        vm.expectRevert(TakasureReserve.TakasureReserve__WrongServiceFee.selector);
        takasureReserve.setNewServiceFee(newServiceFee);
    }

    /// @dev `setNewMinimumThreshold` must revert if the caller is not the admin
    function testTakasureCore_setNewMinimumThresholdMustRevertIfTheCallerIsNotTheAdmin() public {
        uint8 newThreshold = 50;
        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setNewMinimumThreshold(newThreshold);
    }

    /// @dev `setNewFeeClaimAddress` must revert if the caller is not the admin
    function testTakasureCore_setNewFeeClaimAddressMustRevertIfTheCallerIsNotTheAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setNewFeeClaimAddress(alice);
    }

    /// @dev `setNewFeeClaimAddress` must revert if the address is zero
    function testTakasureCore_setNewFeeClaimAddressMustRevertIfAddressZero() public {
        vm.prank(admin);
        vm.expectRevert(AddressAndStates.TakasureProtocol__ZeroAddress.selector);
        takasureReserve.setNewFeeClaimAddress(address(0));
    }

    /// @dev `setAllowCustomDuration` must revert if the caller is not the admin
    function testTakasureCore_setAllowCustomDurationMustRevertIfTheCallerIsNotTheAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setAllowCustomDuration(true);
    }

    function testTakasureCore_onlyDaoAndTakadaoCanSetNewBenefitMultiplier() public {
        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setNewBenefitMultiplierConsumerAddress(alice);

        vm.prank(admin);
        vm.expectEmit(true, true, false, false, address(takasureReserve));
        emit TakasureEvents.OnBenefitMultiplierConsumerChanged(alice, address(bmConsumerMock));
        takasureReserve.setNewBenefitMultiplierConsumerAddress(alice);

        vm.prank(takadao);
        vm.expectEmit(true, true, false, false, address(takasureReserve));
        emit TakasureEvents.OnBenefitMultiplierConsumerChanged(address(bmConsumerMock), alice);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));
    }
}
