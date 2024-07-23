// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "../../../../scripts/foundry-deploy/DeployTokenAndPool.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "../../../../contracts/takasure/TakasurePool.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "../../../../contracts/mocks/IUSDCmock.sol";

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

    event OnMemberKycVerified(address indexed member);

    function setUp() public {
        deployer = new DeployTokenAndPool();
        (, proxy, , contributionTokenAddress, ) = deployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        vm.startPrank(alice);
        usdc.mintUSDC(alice, USDC_INITIAL_AMOUNT);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
    }

    /// @dev Test the owner can set a new wakala fee
    function testTakasurePool_setNewWakalaFee() public {
        uint8 newWakalaFee = 50;

        vm.prank(takasurePool.owner());
        takasurePool.setNewWakalaFee(newWakalaFee);

        (, , , , , , , , , uint8 wakalaFee, , ) = takasurePool.getReserveValues();

        assertEq(newWakalaFee, wakalaFee);
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

    /// @dev Test the owner can set a new wakala claim address
    function testTakasurePool_canSetNewWakalaClaimAddress() public {
        vm.prank(takasurePool.owner());
        takasurePool.setNewWakalaClaimAddress(alice);

        assertEq(alice, takasurePool.wakalaClaimAddress());
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
        emit OnMemberKycVerified(alice);
        takasurePool.setKYCStatus(alice);

        bool getMemberKYCstatusAfter = takasurePool.getMemberKYCStatus(alice);

        assert(!getMemberKYCstatusBefore);
        assert(getMemberKYCstatusAfter);
    }
}
