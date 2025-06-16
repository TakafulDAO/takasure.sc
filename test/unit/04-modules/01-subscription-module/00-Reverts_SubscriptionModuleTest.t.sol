// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {UserRouter} from "contracts/router/UserRouter.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";

contract Reverts_SubscriptionModuleTest is StdCheats, Test {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    SubscriptionModule subscriptionModule;
    UserRouter userRouter;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address admin;
    address kycService;
    address takadao;
    address subscriptionModuleAddress;
    address userRouterAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public david = makeAddr("david");
    uint256 public constant USDC_INITIAL_AMOUNT = 150e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new TestDeployProtocol();
        (
            ,
            takasureReserveProxy,
            ,
            subscriptionModuleAddress,
            ,
            ,
            ,
            userRouterAddress,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        subscriptionModule = SubscriptionModule(subscriptionModuleAddress);
        userRouter = UserRouter(userRouterAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        kycService = config.kycProvider;
        takadao = config.takadaoOperator;

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);
        deal(address(usdc), bob, USDC_INITIAL_AMOUNT);
        deal(address(usdc), charlie, USDC_INITIAL_AMOUNT);
        deal(address(usdc), david, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        vm.startPrank(bob);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        vm.startPrank(charlie);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        vm.startPrank(david);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    /// @dev `paySubscription` must revert if the contribution is less than the minimum threshold
    function testSubscriptionModule_paySubscriptionMustRevertIfDepositLessThanMinimum() public {
        uint256 wrongContribution = CONTRIBUTION_AMOUNT / 2;
        vm.prank(alice);
        vm.expectRevert(SubscriptionModule.SubscriptionModule__InvalidContribution.selector);
        userRouter.paySubscription(address(0), wrongContribution, (5 * YEAR));
    }

    /// @dev can not refund someone already refunded
    function testSubscriptionModule_refundRevertIfMemberAlreadyRefunded() public {
        deal(address(usdc), address(subscriptionModule), 25e6);

        vm.startPrank(alice);
        // Join and refund
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, 5 * YEAR);

        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        subscriptionModule.refund();

        // Try to refund again
        vm.expectRevert(SubscriptionModule.SubscriptionModule__NothingToRefund.selector);
        subscriptionModule.refund();
        vm.stopPrank();
    }

    /// @dev can not refund after 30 days
    function testSubscriptionModule_refundRevertIfMemberRefundAfter30Days() public {
        // Join
        vm.startPrank(alice);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        vm.warp(31 days);
        vm.roll(block.number + 1);

        // Try to refund
        vm.startPrank(alice);
        vm.expectRevert(SubscriptionModule.SubscriptionModule__TooEarlytoRefund.selector);
        subscriptionModule.refund();
        vm.stopPrank();
    }
}
