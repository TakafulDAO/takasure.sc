// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {Reserve} from "contracts/types/TakasureTypes.sol";

contract Getters_TakasurePoolTest is StdCheats, Test {
    TestDeployTakasure deployer;
    TakasurePool takasurePool;
    address proxy;
    address contributionTokenAddress;
    IUSDC usdc;
    address public user = makeAddr("user");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC

    function setUp() public {
        deployer = new TestDeployTakasure();
        (, proxy, contributionTokenAddress, ) = deployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        vm.startPrank(user);
        usdc.mintUSDC(user, USDC_INITIAL_AMOUNT);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
    }

    function testTakasurePool_getServiceFee() public view {
        Reserve memory reserve = takasurePool.getReserveValues();
        uint8 expectedServiceFee = 22;
        assertEq(reserve.serviceFee, expectedServiceFee);
    }

    function testTakasurePool_getMinimumThreshold() public view {
        uint256 minimumThresholdSlot = 21;
        bytes32 minimumThreshold = vm.load(
            address(takasurePool),
            bytes32(uint256(minimumThresholdSlot))
        );
        uint256 minimum = uint256(minimumThreshold);
        uint256 expectedMinimumThreshold = 25e6;
        assertEq(minimum, expectedMinimumThreshold);
    }
}
