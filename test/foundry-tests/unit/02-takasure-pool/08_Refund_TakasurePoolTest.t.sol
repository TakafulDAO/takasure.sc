// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "../../../../scripts/foundry-deploy/DeployTokenAndPool.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "../../../../contracts/takasure/TakasurePool.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState} from "../../../../contracts/types/TakasureTypes.sol";
import {IUSDC} from "../../../../contracts/mocks/IUSDCmock.sol";

contract Refund_TakasurePoolTest is StdCheats, Test {
    DeployTokenAndPool deployer;
    TakasurePool takasurePool;
    ERC1967Proxy proxy;
    address contributionTokenAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 150e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant BENEFIT_MULTIPLIER = 0;
    uint256 public constant YEAR = 365 days;

    event OnRefund(address indexed member, uint256 indexed amount);

    function setUp() public {
        deployer = new DeployTokenAndPool();
        (, proxy, , contributionTokenAddress, ) = deployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank;
    }

    function testTakasurePool_refundContribution() public {
        (, , , , , , , , , uint8 wakalaFee, , ) = takasurePool.getReserveValues();
        uint256 expectedRefundAmount = (CONTRIBUTION_AMOUNT * (100 - wakalaFee)) / 100;

        uint256 contractBalanceBeforeRefund = usdc.balanceOf(address(takasurePool));
        uint256 aliceBalanceBeforeRefund = usdc.balanceOf(alice);

        vm.startPrank(alice);
        vm.expectEmit(true, true, false, false, address(takasurePool));
        emit OnRefund(alice, expectedRefundAmount);
        takasurePool.refund();
        vm.stopPrank();

        uint256 contractBalanceAfterRefund = usdc.balanceOf(address(takasurePool));
        uint256 aliceBalanceAfterRefund = usdc.balanceOf(alice);

        assertEq(contractBalanceBeforeRefund - expectedRefundAmount, contractBalanceAfterRefund);
        assertEq(aliceBalanceBeforeRefund + expectedRefundAmount, aliceBalanceAfterRefund);
    }
}
