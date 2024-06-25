// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "../../../../scripts/foundry-deploy/DeployTokenAndPool.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "../../../../contracts/takasure/TakasurePool.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "../../../../contracts/mocks/IUSDCmock.sol";

contract Reverts_TakasurePoolTest is StdCheats, Test {
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
        (, proxy, , contributionTokenAddress, ) = deployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.prank(alice);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/
    /// @dev `setNewWakalaFee` must revert if the caller is not the owner
    function testTakasurePool_setNewWakalaFeeMustRevertIfTheCallerIsNotTheOwner() public {
        uint8 newWakalaFee = 50;
        vm.prank(alice);
        vm.expectRevert();
        takasurePool.setNewWakalaFee(newWakalaFee);
    }

    /// @dev `setNewWakalaFee` must revert if it is higher than 100
    function testTakasurePool_setNewWakalaFeeMustRevertIfHigherThan100() public {
        uint8 newWakalaFee = 101;
        vm.prank(takasurePool.owner());
        vm.expectRevert(TakasurePool.TakasurePool__WrongWakalaFee.selector);
        takasurePool.setNewWakalaFee(newWakalaFee);
    }

    /// @dev `setNewMinimumThreshold` must revert if the caller is not the owner
    function testTakasurePool_setNewMinimumThresholdMustRevertIfTheCallerIsNotTheOwner() public {
        uint8 newThreshold = 50;
        vm.prank(alice);
        vm.expectRevert();
        takasurePool.setNewMinimumThreshold(newThreshold);
    }

    /// @dev `setNewContributionToken` must revert if the caller is not the owner
    function testTakasurePool_setNewContributionTokenMustRevertIfTheCallerIsNotTheOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        takasurePool.setNewContributionToken(alice);
    }

    /// @dev `setNewContributionToken` must revert if the address is zero
    function testTakasurePool_setNewContributionTokenMustRevertIfAddressZero() public {
        vm.prank(takasurePool.owner());
        vm.expectRevert(TakasurePool.TakasurePool__ZeroAddress.selector);
        takasurePool.setNewContributionToken(address(0));
    }

    /// @dev `setNewWakalaClaimAddress` must revert if the caller is not the owner
    function testTakasurePool_setNewWakalaClaimAddressMustRevertIfTheCallerIsNotTheOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        takasurePool.setNewWakalaClaimAddress(alice);
    }

    /// @dev `setNewWakalaClaimAddress` must revert if the address is zero
    function testTakasurePool_setNewWakalaClaimAddressMustRevertIfAddressZero() public {
        vm.prank(takasurePool.owner());
        vm.expectRevert(TakasurePool.TakasurePool__ZeroAddress.selector);
        takasurePool.setNewWakalaClaimAddress(address(0));
    }

    /// @dev `setAllowCustomDuration` must revert if the caller is not the owner
    function testTakasurePool_setAllowCustomDurationMustRevertIfTheCallerIsNotTheOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        takasurePool.setAllowCustomDuration(true);
    }

    /// @dev `joinPool` must revert if the contribution is less than the minimum threshold
    function testTakasurePool_joinPoolMustRevertIfDepositLessThanMinimum() public {
        uint256 wrongContribution = CONTRIBUTION_AMOUNT / 2;
        vm.prank(alice);
        vm.expectRevert(TakasurePool.TakasurePool__ContributionBelowMinimumThreshold.selector);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, wrongContribution, (5 * YEAR));
    }

    /// @dev If it is an active member, can not join again
    function testTakasurePool_activeShouldNotMemberJoinAgain() public {
        vm.startPrank(alice);
        // Alice joins the pool
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));

        // And tries to join again but fails
        vm.expectRevert(TakasurePool.TakasurePool__MemberAlreadyExists.selector);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        vm.stopPrank();
    }

    /// @dev `setKYCStatus` must revert if the member is address zero
    function testTakasurePool_setKYCStatusMustRevertIfMemberIsZero() public {
        vm.prank(takasurePool.owner());
        vm.expectRevert(TakasurePool.TakasurePool__ZeroAddress.selector);
        takasurePool.setKYCStatus(address(0));
    }

    /// @dev `setKYCStatus` must revert if the member is already KYC verified
    function testTakasurePool_setKYCStatusMustRevertIfMemberIsAlreadyKYCVerified() public {
        vm.prank(alice);
        // Alice joins the pool
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));

        vm.startPrank(takasurePool.owner());
        takasurePool.setKYCStatus(alice);

        // And tries to join again but fails
        vm.expectRevert(TakasurePool.TakasurePool__MemberAlreadyKYCed.selector);
        takasurePool.setKYCStatus(alice);
        vm.stopPrank();
    }
}
