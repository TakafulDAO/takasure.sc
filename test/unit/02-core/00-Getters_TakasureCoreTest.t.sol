// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {Reserve} from "contracts/types/TakasureTypes.sol";

contract Getters_TakasureCoreTest is StdCheats, Test {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    address takasureReserveProxy;
    address contributionTokenAddress;
    IUSDC usdc;
    address public user = makeAddr("user");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC

    function setUp() public {
        deployer = new TestDeployProtocol();
        (, , takasureReserveProxy, , , , , , contributionTokenAddress, , ) = deployer.run();

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        vm.startPrank(user);
        usdc.mintUSDC(user, USDC_INITIAL_AMOUNT);
        usdc.approve(address(takasureReserve), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
    }

    function testTakasureCore_getServiceFee() public view {
        Reserve memory reserve = takasureReserve.getReserveValues();
        uint8 expectedServiceFee = 22;
        assertEq(reserve.serviceFee, expectedServiceFee);
    }

    function testTakasureCore_getMinimumThreshold() public view {
        Reserve memory reserve = takasureReserve.getReserveValues();
        uint256 expectedMinimumThreshold = 25e6;
        assertEq(reserve.minimumThreshold, expectedMinimumThreshold);
    }
}
