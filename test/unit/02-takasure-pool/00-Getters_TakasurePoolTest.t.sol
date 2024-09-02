// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract Getters_TakasurePoolTest is StdCheats, Test {
    TestDeployTakasure deployer;
    TakasurePool takasurePool;
    address proxy;

    function setUp() public {
        deployer = new TestDeployTakasure();
        (, proxy, , ) = deployer.run();

        takasurePool = TakasurePool(address(proxy));
    }

    function testTakasurePool_getServiceFee() public view {
        uint8 serviceFee = takasurePool.getCurrentServiceFee();
        uint8 expectedServiceFee = 22;
        assertEq(serviceFee, expectedServiceFee);
    }

    function testTakasurePool_getMinimumThreshold() public view {
        uint256 minimumThreshold = takasurePool.minimumThreshold();
        uint256 expectedMinimumThreshold = 25e6;
        assertEq(minimumThreshold, expectedMinimumThreshold);
    }
}
