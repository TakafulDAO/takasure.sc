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
    address public user = makeAddr("user");
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
        vm.startPrank(user);
        usdc.mintUSDC(user, USDC_INITIAL_AMOUNT);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/
    /// @dev `setNewWakalaFee` must revert if the caller is not the owner
    function testTakasurePool_setNewWakalaFeeMustRevertIfTheCallerIsNotTheOwner() public {
        uint8 newWakalaFee = 50;
        vm.prank(user);
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
        vm.prank(user);
        vm.expectRevert();
        takasurePool.setNewMinimumThreshold(newThreshold);
    }

    /// @dev `setNewContributionToken` must revert if the caller is not the owner
    function testTakasurePool_setNewContributionTokenMustRevertIfTheCallerIsNotTheOwner() public {
        vm.prank(user);
        vm.expectRevert();
        takasurePool.setNewContributionToken(user);
    }

    /// @dev `setNewContributionToken` must revert if the address is zero
    function testTakasurePool_setNewContributionTokenMustRevertIfAddressZero() public {
        vm.prank(takasurePool.owner());
        vm.expectRevert(TakasurePool.TakasurePool__ZeroAddress.selector);
        takasurePool.setNewContributionToken(address(0));
    }

    /// @dev `setNewWakalaClaimAddress` must revert if the caller is not the owner
    function testTakasurePool_setNewWakalaClaimAddressMustRevertIfTheCallerIsNotTheOwner() public {
        vm.prank(user);
        vm.expectRevert();
        takasurePool.setNewWakalaClaimAddress(user);
    }

    /// @dev `setNewWakalaClaimAddress` must revert if the address is zero
    function testTakasurePool_setNewWakalaClaimAddressMustRevertIfAddressZero() public {
        vm.prank(takasurePool.owner());
        vm.expectRevert(TakasurePool.TakasurePool__ZeroAddress.selector);
        takasurePool.setNewWakalaClaimAddress(address(0));
    }

    /// @dev `setAllowCustomDuration` must revert if the caller is not the owner
    function testTakasurePool_setAllowCustomDurationMustRevertIfTheCallerIsNotTheOwner() public {
        vm.prank(user);
        vm.expectRevert();
        takasurePool.setAllowCustomDuration(true);
    }

    /// @dev `joinPool` must revert if the contribution is less than the minimum threshold
    function testTakasurePool_joinPoolMustRevertIfDepositLessThanMinimum() public {
        uint256 wrongContribution = CONTRIBUTION_AMOUNT / 2;
        vm.prank(user);
        vm.expectRevert(TakasurePool.TakasurePool__ContributionBelowMinimumThreshold.selector);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, wrongContribution, (5 * YEAR));
    }
}
