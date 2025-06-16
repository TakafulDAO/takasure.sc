// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {KYCModule} from "contracts/modules/KYCModule.sol";
import {UserRouter} from "contracts/router/UserRouter.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, Reserve} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";

contract Surplus_TakasureCoreTest is StdCheats, Test {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    SubscriptionModule subscriptionModule;
    KYCModule kycModule;
    UserRouter userRouter;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address admin;
    address kycService;
    address takadao;
    address subscriptionModuleAddress;
    address kycModuleAddress;
    address userRouterAddress;
    IUSDC usdc;
    uint256 public constant USDC_INITIAL_AMOUNT = 500e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant YEAR = 365 days;
    uint256 public constant BM = 1;

    // Users
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public david = makeAddr("david");
    address public erin = makeAddr("erin");
    address public frank = makeAddr("frank");

    function setUp() public {
        deployer = new TestDeployProtocol();
        (
            ,
            takasureReserveProxy,
            ,
            subscriptionModuleAddress,
            kycModuleAddress,
            ,
            ,
            userRouterAddress,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        subscriptionModule = SubscriptionModule(subscriptionModuleAddress);
        kycModule = KYCModule(kycModuleAddress);
        userRouter = UserRouter(userRouterAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        kycService = config.kycProvider;
        takadao = config.takadaoOperator;

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);
    }

    modifier tokensTo(address user) {
        deal(address(usdc), user, USDC_INITIAL_AMOUNT);
        vm.startPrank(user);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testTakasureCore_surplus()
        public
        tokensTo(alice)
        tokensTo(bob)
        tokensTo(charlie)
        tokensTo(david)
        tokensTo(erin)
        tokensTo(frank)
    {
        // Alice joins in day 1
        _join(alice, 1);
        Reserve memory reserve = takasureReserve.getReserveValues();
        uint256 ECRes = reserve.ECRes;
        uint256 UCRes = reserve.UCRes;
        uint256 surplus = reserve.surplus;
        Member memory ALICE = takasureReserve.getMemberFromAddress(alice);
        assertEq(ALICE.lastEcr, 0);
        assertEq(ALICE.lastUcr, 0);
        assertEq(ECRes, 0);
        assertEq(UCRes, 0);
        assertEq(surplus, 0);
        // Bob joins in day 1
        _join(bob, 3);
        reserve = takasureReserve.getReserveValues();
        ECRes = reserve.ECRes;
        UCRes = reserve.UCRes;
        surplus = reserve.surplus;
        ALICE = takasureReserve.getMemberFromAddress(alice);
        Member memory BOB = takasureReserve.getMemberFromAddress(bob);
        assertEq(ALICE.lastEcr, 10_950_000);
        assertEq(ALICE.lastUcr, 0);
        assertEq(BOB.lastEcr, 0);
        assertEq(BOB.lastUcr, 0);
        assertEq(ECRes, 10_950_000);
        assertEq(UCRes, 0);
        assertEq(surplus, 10_950_000);
        // 1 day passes
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // Charlie joins in day 2
        _join(charlie, 10);
        reserve = takasureReserve.getReserveValues();
        ECRes = reserve.ECRes;
        UCRes = reserve.UCRes;
        surplus = reserve.surplus;
        ALICE = takasureReserve.getMemberFromAddress(alice);
        BOB = takasureReserve.getMemberFromAddress(bob);
        Member memory CHARLIE = takasureReserve.getMemberFromAddress(charlie);
        assertEq(ALICE.lastEcr, 10_920_000);
        assertEq(ALICE.lastUcr, 30_000);
        assertEq(BOB.lastEcr, 28_392_000);
        assertEq(BOB.lastUcr, 78_000);
        assertEq(CHARLIE.lastEcr, 0);
        assertEq(CHARLIE.lastUcr, 0);
        assertEq(ECRes, 39_312_000);
        assertEq(UCRes, 108_000);
        assertEq(surplus, 39_312_000);
        // 1 day passes
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // David joins in day 3
        _join(david, 5);
        reserve = takasureReserve.getReserveValues();
        ECRes = reserve.ECRes;
        UCRes = reserve.UCRes;
        surplus = reserve.surplus;
        ALICE = takasureReserve.getMemberFromAddress(alice);
        BOB = takasureReserve.getMemberFromAddress(bob);
        CHARLIE = takasureReserve.getMemberFromAddress(charlie);
        Member memory DAVID = takasureReserve.getMemberFromAddress(david);
        assertEq(ALICE.lastEcr, 10_890_000);
        assertEq(ALICE.lastUcr, 60_000);
        assertEq(BOB.lastEcr, 28_314_000);
        assertEq(BOB.lastUcr, 156_000);
        assertEq(CHARLIE.lastEcr, 103_740_000);
        assertEq(CHARLIE.lastUcr, 285_000);
        assertEq(DAVID.lastEcr, 0);
        assertEq(DAVID.lastUcr, 0);
        assertEq(ECRes, 142_944_000);
        assertEq(UCRes, 501_000);
        assertEq(surplus, 142_944_000);
        // 1 day passes
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // Erin joins in day 4
        _join(erin, 2);
        reserve = takasureReserve.getReserveValues();
        ECRes = reserve.ECRes;
        UCRes = reserve.UCRes;
        surplus = reserve.surplus;
        ALICE = takasureReserve.getMemberFromAddress(alice);
        BOB = takasureReserve.getMemberFromAddress(bob);
        CHARLIE = takasureReserve.getMemberFromAddress(charlie);
        DAVID = takasureReserve.getMemberFromAddress(david);
        Member memory ERIN = takasureReserve.getMemberFromAddress(erin);
        assertEq(ALICE.lastEcr, 10_860_000);
        assertEq(ALICE.lastUcr, 90_000);
        assertEq(BOB.lastEcr, 28_236_000);
        assertEq(BOB.lastUcr, 234_000);
        assertEq(CHARLIE.lastEcr, 103_455_000);
        assertEq(CHARLIE.lastUcr, 570_000);
        assertEq(DAVID.lastEcr, 50_960_000);
        assertEq(DAVID.lastUcr, 140_000);
        assertEq(ERIN.lastEcr, 0);
        assertEq(ERIN.lastUcr, 0);
        assertEq(ECRes, 193_511_000);
        assertEq(UCRes, 1_034_000);
        assertEq(surplus, 193_511_000);
        // 1 day passes
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // Frank joins in day 5
        _join(frank, 7);
        reserve = takasureReserve.getReserveValues();
        ECRes = reserve.ECRes;
        UCRes = reserve.UCRes;
        surplus = reserve.surplus;
        ALICE = takasureReserve.getMemberFromAddress(alice);
        BOB = takasureReserve.getMemberFromAddress(bob);
        CHARLIE = takasureReserve.getMemberFromAddress(charlie);
        DAVID = takasureReserve.getMemberFromAddress(david);
        ERIN = takasureReserve.getMemberFromAddress(erin);
        Member memory FRANK = takasureReserve.getMemberFromAddress(frank);
        assertEq(ALICE.lastEcr, 10_830_000);
        assertEq(ALICE.lastUcr, 120_000);
        assertEq(BOB.lastEcr, 28_158_000);
        assertEq(BOB.lastUcr, 312_000);
        assertEq(CHARLIE.lastEcr, 103_170_000);
        assertEq(CHARLIE.lastUcr, 855_000);
        assertEq(DAVID.lastEcr, 50_820_000);
        assertEq(DAVID.lastUcr, 280_000);
        assertEq(ERIN.lastEcr, 20_384_000);
        assertEq(ERIN.lastUcr, 56_000);
        assertEq(FRANK.lastEcr, 0);
        assertEq(FRANK.lastUcr, 0);
        assertEq(ECRes, 213_362_000);
        assertEq(UCRes, 1_623_000);
        assertEq(surplus, 213_362_000);
    }

    function _join(address user, uint256 timesContributionAmount) internal {
        vm.startPrank(user);
        userRouter.paySubscription(
            address(0),
            timesContributionAmount * CONTRIBUTION_AMOUNT,
            5 * YEAR
        );
        vm.stopPrank();

        vm.startPrank(admin);
        kycModule.approveKYC(user, BM);
        vm.stopPrank();
    }
}
