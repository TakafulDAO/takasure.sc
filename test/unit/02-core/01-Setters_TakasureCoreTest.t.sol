// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {Member, Reserve, CashFlowVars} from "contracts/types/TakasureTypes.sol";

contract Setters_TakasureCoreTest is StdCheats, Test {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address admin;
    address kycService;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC

    function setUp() public {
        deployer = new TestDeployProtocol();
        (, takasureReserveProxy, , , , , , , contributionTokenAddress, , helperConfig) = deployer
            .run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        kycService = config.kycProvider;

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(takasureReserve), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
    }

    /// @dev Test the owner can set a new service fee
    function testTakasureReserve_setNewServiceFeeToNewValue() public {
        assert(2 + 2 == 4);
        uint8 newServiceFee = 35;

        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(takasureReserve));
        emit TakasureEvents.OnServiceFeeChanged(newServiceFee);
        takasureReserve.setNewServiceFee(newServiceFee);

        uint8 serviceFee = takasureReserve.getReserveValues().serviceFee;

        assertEq(newServiceFee, serviceFee);
    }

    /// @dev Test the owner can set a new minimum threshold
    function testTakasureCore_setNewMinimumThreshold() public {
        uint256 newMinimumThreshold = 50e6;

        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(takasureReserve));
        emit TakasureEvents.OnNewMinimumThreshold(newMinimumThreshold);
        takasureReserve.setNewMinimumThreshold(newMinimumThreshold);

        assertEq(newMinimumThreshold, takasureReserve.getReserveValues().minimumThreshold);
    }

    /// @dev Test the owner can set a new minimum threshold
    function testTakasureCore_setNewMaximumThreshold() public {
        uint256 newMaximumThreshold = 50e6;

        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(takasureReserve));
        emit TakasureEvents.OnNewMaximumThreshold(newMaximumThreshold);
        takasureReserve.setNewMaximumThreshold(newMaximumThreshold);

        assertEq(newMaximumThreshold, takasureReserve.getReserveValues().maximumThreshold);
    }

    /// @dev Test the owner can set custom duration
    function testTakasureCore_setAllowCustomDuration() public {
        vm.prank(admin);
        takasureReserve.setAllowCustomDuration(true);

        assertEq(true, takasureReserve.getReserveValues().allowCustomDuration);
    }

    function testTakasureCore_setAddressManagerContract() public {
        vm.prank(admin);
        takasureReserve.setAddressManagerContract(alice);

        assertEq(alice, address(takasureReserve.addressManager()));

        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setAddressManagerContract(admin);
    }

    function testTakasureCore_onlyModuleFunctions() public {
        Member memory member;
        Reserve memory reserve;
        CashFlowVars memory cashFlowVars;

        vm.startPrank(admin);
        vm.expectRevert(TakasureReserve.TakasureReserve__UnallowedAccess.selector);
        takasureReserve.setMemberValuesFromModule(member);

        vm.expectRevert(TakasureReserve.TakasureReserve__UnallowedAccess.selector);
        takasureReserve.setReserveValuesFromModule(reserve);

        vm.expectRevert(TakasureReserve.TakasureReserve__UnallowedAccess.selector);
        takasureReserve.setCashFlowValuesFromModule(cashFlowVars);

        vm.expectRevert(TakasureReserve.TakasureReserve__UnallowedAccess.selector);
        takasureReserve.setMonthToCashFlowValuesFromModule(0, 0);

        vm.expectRevert(TakasureReserve.TakasureReserve__UnallowedAccess.selector);
        takasureReserve.setDayToCashFlowValuesFromModule(0, 0, 0);

        vm.expectRevert(TakasureReserve.TakasureReserve__UnallowedAccess.selector);
        takasureReserve.memberSurplus(member);
        vm.stopPrank();
    }

    function testTakasureCore_setNewFundMarketExpendsShare() public {
        vm.prank(admin);
        takasureReserve.setNewFundMarketExpendsShare(10);

        vm.prank(admin);
        vm.expectRevert(TakasureReserve.TakasureReserve__WrongValue.selector);
        takasureReserve.setNewFundMarketExpendsShare(36);

        vm.prank(alice);
        vm.expectRevert();
        takasureReserve.setNewFundMarketExpendsShare(10);
    }
}
