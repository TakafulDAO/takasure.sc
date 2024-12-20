// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

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
        (, , proxy, , contributionTokenAddress, , ) = deployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        vm.startPrank(user);
        usdc.mintUSDC(user, USDC_INITIAL_AMOUNT);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
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
