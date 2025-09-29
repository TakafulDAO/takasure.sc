// // SPDX-License-Identifier: GPL-3.0

// pragma solidity 0.8.28;

// import {Test, console2} from "forge-std/Test.sol";
// import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
// import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
// import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
// import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
// import {UserRouter} from "contracts/router/UserRouter.sol";
// import {StdCheats} from "forge-std/StdCheats.sol";
// import {Member, Reserve} from "contracts/types/TakasureTypes.sol";
// import {IUSDC} from "test/mocks/IUSDCmock.sol";

// contract Join_SubscriptionModuleTest is StdCheats, Test {
//     TestDeployProtocol deployer;
//     TakasureReserve takasureReserve;
//     HelperConfig helperConfig;
//     SubscriptionModule subscriptionModule;
//     UserRouter userRouter;
//     address takasureReserveProxy;
//     address contributionTokenAddress;
//     address admin;
//     address kycService;
//     address takadao;
//     address subscriptionModuleAddress;
//     address userRouterAddress;
//     IUSDC usdc;
//     address public alice = makeAddr("alice");
//     address public bob = makeAddr("bob");
//     uint256 public constant USDC_INITIAL_AMOUNT = 1000e6; // 1000 USDC
//     uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
//     uint256 public constant BENEFIT_MULTIPLIER = 0;
//     uint256 public constant YEAR = 365 days;

//     function setUp() public {
//         deployer = new TestDeployProtocol();
//         (
//             takasureReserveProxy,
//             ,
//             subscriptionModuleAddress,
//             ,
//             ,
//             ,
//             ,
//             userRouterAddress,
//             contributionTokenAddress,
//             ,
//             helperConfig
//         ) = deployer.run();

//         subscriptionModule = SubscriptionModule(subscriptionModuleAddress);
//         userRouter = UserRouter(userRouterAddress);

//         HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

//         admin = config.daoMultisig;
//         kycService = config.kycProvider;
//         takadao = config.takadaoOperator;

//         takasureReserve = TakasureReserve(takasureReserveProxy);
//         usdc = IUSDC(contributionTokenAddress);

//         // For easier testing there is a minimal USDC mock contract without restrictions
//         deal(address(usdc), alice, USDC_INITIAL_AMOUNT);
//         deal(address(usdc), bob, USDC_INITIAL_AMOUNT);

//         vm.startPrank(alice);
//         usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
//         vm.stopPrank();
//         vm.startPrank(bob);
//         usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
//         vm.stopPrank();
//     }

//     /*//////////////////////////////////////////////////////////////
//                       JOIN POOL::CREATE NEW MEMBER
//     //////////////////////////////////////////////////////////////*/

//     /// @dev Test that the paySubscription function updates the memberIdCounter
//     function testSubscriptionModule_paySubscriptionUpdatesCounter() public {
//         uint256 memberIdCounterBeforeAlice = takasureReserve.getReserveValues().memberIdCounter;

//         vm.prank(alice);
//         userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

//         uint256 memberIdCounterAfterAlice = takasureReserve.getReserveValues().memberIdCounter;

//         vm.prank(bob);
//         userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

//         uint256 memberIdCounterAfterBob = takasureReserve.getReserveValues().memberIdCounter;

//         assertEq(memberIdCounterAfterAlice, memberIdCounterBeforeAlice + 1);
//         assertEq(memberIdCounterAfterBob, memberIdCounterAfterAlice + 1);
//     }

//     function testSubscriptionModule_paySubscriptionTransferAmountsCorrectly() public {
//         uint256 aliceBalanceBefore = usdc.balanceOf(alice);

//         vm.prank(alice);
//         userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

//         uint256 aliceBalanceAfter = usdc.balanceOf(alice);

//         assertEq(aliceBalanceAfter, aliceBalanceBefore - CONTRIBUTION_AMOUNT);
//     }

//     /// @dev Test the membership custom duration
//     function testSubscriptionModule_customMembershipDuration() public {
//         vm.prank(admin);
//         takasureReserve.setAllowCustomDuration(true);

//         vm.prank(alice);
//         userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, YEAR);

//         Member memory member = takasureReserve.getMemberFromAddress(alice);

//         assertEq(member.membershipDuration, YEAR);
//     }

//     /// @dev Test the member is created
//     function testSubscriptionModule_newMember() public {
//         vm.prank(alice);
//         userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

//         uint256 memberId = takasureReserve.getReserveValues().memberIdCounter;

//         // Check the member is created and added correctly to mappings
//         Member memory testMember = takasureReserve.getMemberFromAddress(alice);

//         assertEq(testMember.memberId, memberId);
//         assertEq(testMember.benefitMultiplier, BENEFIT_MULTIPLIER);
//         assertEq(testMember.contribution, CONTRIBUTION_AMOUNT);
//         assertEq(testMember.wallet, alice);
//         assertEq(uint8(testMember.memberState), 0);
//     }

//     function testGasBenchMark_paySubscriptionThroughUserRouter() public {
//         // Gas used: 505546
//         vm.prank(alice);
//         userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));
//     }

//     function testGasBenchMark_paySubscriptionThroughsubscriptionModule() public {
//         // Gas used: 495580
//         vm.prank(alice);
//         subscriptionModule.paySubscription(alice, address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));
//     }
// }
