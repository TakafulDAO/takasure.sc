// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "scripts/foundry-deploy/DeployTokenAndPool.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "src/takasure/TakasurePool.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "src/mocks/IUSDCmock.sol";
import {TakasureEvents} from "src/libraries/TakasureEvents.sol";

contract Setters_TakasurePoolTest is StdCheats, Test {
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

    function setUp() public {
        deployer = new DeployTokenAndPool();
        (, proxy, , , contributionTokenAddress, ) = deployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        vm.startPrank(alice);
        usdc.mintUSDC(alice, USDC_INITIAL_AMOUNT);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
    }

    /// @dev Test the owner can set a new service fee
    function testTakasurePool_setNewServiceFeeToNewValue() public {
        uint8 newServiceFee = 35;

        vm.prank(takasurePool.owner());
        vm.expectEmit(true, false, false, false, address(takasurePool));
        emit TakasureEvents.OnServiceFeeChanged(newServiceFee);
        takasurePool.setNewServiceFee(newServiceFee);

        (, , , , , , , , , uint8 serviceFee, , ) = takasurePool.getReserveValues();

        assertEq(newServiceFee, serviceFee);
    }

    /// @dev Test the owner can set a new minimum threshold
    function testTakasurePool_setNewMinimumThreshold() public {
        uint256 newThreshold = 50e6;

        vm.prank(takasurePool.owner());
        takasurePool.setNewMinimumThreshold(newThreshold);

        assertEq(newThreshold, takasurePool.minimumThreshold());
    }

    /// @dev Test the owner can set a new contribution token
    function testTakasurePool_setNewContributionToken() public {
        vm.prank(takasurePool.owner());
        takasurePool.setNewContributionToken(alice);

        assertEq(alice, takasurePool.getContributionTokenAddress());
    }

    /// @dev Test the owner can set a new service claim address
    function testTakasurePool_cansetNewServiceClaimAddress() public {
        vm.prank(takasurePool.owner());
        takasurePool.setNewFeeClaimAddress(alice);

        assertEq(alice, takasurePool.feeClaimAddress());
    }

    /// @dev Test the owner can set custom duration
    function testTakasurePool_setAllowCustomDuration() public {
        vm.prank(takasurePool.owner());
        takasurePool.setAllowCustomDuration(true);

        assertEq(true, takasurePool.allowCustomDuration());
    }

    function testTakasurePool_setKYCstatus() public {
        bool getMemberKYCstatusBefore = takasurePool.getMemberKYCStatus(alice);

        vm.prank(takasurePool.owner());
        vm.expectEmit(true, false, false, false, address(takasurePool));
        emit TakasureEvents.OnMemberKycVerified(1, alice);
        takasurePool.setKYCStatus(alice);

        bool getMemberKYCstatusAfter = takasurePool.getMemberKYCStatus(alice);

        assert(!getMemberKYCstatusBefore);
        assert(getMemberKYCstatusAfter);
    }
}
