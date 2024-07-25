// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "../../../../scripts/foundry-deploy/DeployTokenAndPool.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "../../../../contracts/takasure/TakasurePool.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState} from "../../../../contracts/types/TakasureTypes.sol";
import {IUSDC} from "../../../../contracts/mocks/IUSDCmock.sol";

contract Reserves_TakasurePoolTest is StdCheats, Test {
    DeployTokenAndPool deployer;
    TakasurePool takasurePool;
    ERC1967Proxy proxy;
    address contributionTokenAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant BENEFIT_MULTIPLIER = 0;
    uint256 public constant YEAR = 365 days;

    event MemberJoined(address indexed member, uint256 indexed contributionAmount);

    function setUp() public {
        deployer = new DeployTokenAndPool();
        (, proxy, , contributionTokenAddress, ) = deployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.prank(alice);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                    JOIN POOL::TRANSFER AMOUNTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Test contribution amount is not transferred to the contract if only the KYC is done
    function testTakasurePool_contributionAmountNotTransferToContractWhenOnlyKyc() public {
        uint256 contractBalanceBefore = usdc.balanceOf(address(takasurePool));

        vm.prank(takasurePool.owner());
        takasurePool.setKYCStatus(alice);

        uint256 contractBalanceAfter = usdc.balanceOf(address(takasurePool));

        assertEq(contractBalanceAfter, contractBalanceBefore);
    }

    /// @dev Test contribution amount is transferred to the contract when joins the pool
    function testTakasurePool_contributionAmountTransferToContractWhenJoinPool() public {
        uint256 contractBalanceBefore = usdc.balanceOf(address(takasurePool));

        (, , , , , , , , , uint8 serviceFee, , ) = takasurePool.getReserveValues();

        vm.prank(alice);
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        uint256 contractBalanceAfter = usdc.balanceOf(address(takasurePool));

        uint256 fee = (CONTRIBUTION_AMOUNT * serviceFee) / 100;
        uint256 deposited = CONTRIBUTION_AMOUNT - fee;

        assertEq(contractBalanceAfter, contractBalanceBefore + deposited);
    }

    /// @dev Test service fee is transferred when the member joins the pool
    function testTakasurePool_serviceFeeAmountTransferedWhenJoinsPool() public {
        (, , , , , , , , , uint8 serviceFee, , ) = takasurePool.getReserveValues();
        address serviceFeeReceiver = takasurePool.feeClaimAddress();
        uint256 serviceFeeReceiverBalanceBefore = usdc.balanceOf(serviceFeeReceiver);

        vm.prank(alice);
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        uint256 serviceFeeReceiverBalanceAfter = usdc.balanceOf(serviceFeeReceiver);

        uint256 feeColected = (CONTRIBUTION_AMOUNT * serviceFee) / 100; // 25USDC * 20% = 5USDC

        assertEq(serviceFeeReceiverBalanceAfter, serviceFeeReceiverBalanceBefore + feeColected);
    }
}
