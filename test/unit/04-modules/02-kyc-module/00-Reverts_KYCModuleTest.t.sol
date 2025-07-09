// // SPDX-License-Identifier: GPL-3.0

// pragma solidity 0.8.28;

// import {Test, console2} from "forge-std/Test.sol";
// import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
// import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
// import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
// import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
// import {KYCModule} from "contracts/modules/KYCModule.sol";
// import {StdCheats} from "forge-std/StdCheats.sol";
// import {IUSDC} from "test/mocks/IUSDCmock.sol";
// import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
// import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
// import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";

// contract Reverts_KYCModuleTest is StdCheats, Test {
//     TestDeployProtocol deployer;
//     TakasureReserve takasureReserve;
//     HelperConfig helperConfig;
//     SubscriptionModule subscriptionModule;
//     KYCModule kycModule;
//     address takasureReserveProxy;
//     address contributionTokenAddress;
//     address admin;
//     address kycService;
//     address takadao;
//     address subscriptionModuleAddress;
//     address kycModuleAddress;
//     IUSDC usdc;
//     address public alice = makeAddr("alice");
//     address public bob = makeAddr("bob");
//     address public charlie = makeAddr("charlie");
//     address public david = makeAddr("david");
//     uint256 public constant USDC_INITIAL_AMOUNT = 150e6; // 100 USDC
//     uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
//     uint256 public constant YEAR = 365 days;
//     uint256 public constant BM = 1;

//     function setUp() public {
//         deployer = new TestDeployProtocol();
//         (
//             takasureReserveProxy,
//             ,
//             subscriptionModuleAddress,
//             kycModuleAddress,
//             ,
//             ,
//             ,
//             contributionTokenAddress,
//             ,
//             helperConfig
//         ) = deployer.run();

//         subscriptionModule = SubscriptionModule(subscriptionModuleAddress);
//         kycModule = KYCModule(kycModuleAddress);

//         HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

//         admin = config.daoMultisig;
//         kycService = config.kycProvider;
//         takadao = config.takadaoOperator;

//         takasureReserve = TakasureReserve(takasureReserveProxy);
//         usdc = IUSDC(contributionTokenAddress);

//         // For easier testing there is a minimal USDC mock contract without restrictions
//         deal(address(usdc), alice, USDC_INITIAL_AMOUNT);
//         deal(address(usdc), bob, USDC_INITIAL_AMOUNT);
//         deal(address(usdc), charlie, USDC_INITIAL_AMOUNT);
//         deal(address(usdc), david, USDC_INITIAL_AMOUNT);

//         vm.startPrank(alice);
//         usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
//         vm.stopPrank();
//         vm.startPrank(bob);
//         usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
//         vm.stopPrank();
//         vm.startPrank(charlie);
//         usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
//         vm.stopPrank();
//         vm.startPrank(david);
//         usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
//         vm.stopPrank();

//         vm.prank(alice);
//         // Alice pays for the subscription
//         subscriptionModule.paySubscription(alice, address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));
//     }

//     /*//////////////////////////////////////////////////////////////
//                                 REVERTS
//     //////////////////////////////////////////////////////////////*/

//     /// @dev If it is an active member, can not join again
//     function testSubscriptionModule_activeMembersShouldNotJoinAgain() public {
//         vm.prank(admin);
//         kycModule.approveKYC(alice, BM);

//         vm.prank(alice);
//         // And tries to join again but fails
//         vm.expectRevert(SubscriptionModule.SubscriptionModule__AlreadyJoined.selector);
//         subscriptionModule.paySubscription(alice, address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));
//     }

//     /// @dev `approveKYC` must revert if the member is address zero
//     function testSubscriptionModule_approveKYCMustRevertIfMemberIsAddressZero() public {
//         vm.prank(admin);

//         vm.expectRevert(AddressAndStates.TakasureProtocol__ZeroAddress.selector);
//         kycModule.approveKYC(address(0), BM);
//     }

//     /// @dev `approveKYC` must revert if the member is already KYC verified
//     function testSubscriptionModule_approveKYCMustRevertIfMemberIsAlreadyKYCVerified() public {
//         vm.startPrank(admin);
//         kycModule.approveKYC(alice, BM);

//         // And tries to join again but fails
//         vm.expectRevert(KYCModule.KYCModule__MemberAlreadyKYCed.selector);
//         kycModule.approveKYC(alice, BM);

//         vm.stopPrank();
//     }

//     function testSubscriptionModule_revertIfTryToJoinTwice() public {
//         vm.prank(admin);
//         kycModule.approveKYC(alice, BM);

//         vm.prank(alice);
//         vm.expectRevert(SubscriptionModule.SubscriptionModule__AlreadyJoined.selector);
//         subscriptionModule.paySubscription(alice, address(0), CONTRIBUTION_AMOUNT, 5 * YEAR);

//         // Second check bob join -> bob join again must revert
//         vm.startPrank(bob);
//         subscriptionModule.paySubscription(bob, address(0), CONTRIBUTION_AMOUNT, 5 * YEAR);
//         vm.expectRevert(SubscriptionModule.SubscriptionModule__AlreadyJoined.selector);
//         subscriptionModule.paySubscription(bob, address(0), CONTRIBUTION_AMOUNT, 5 * YEAR);
//         vm.stopPrank();

//         // Third check charlie join -> 14 days passes -> refund charlie -> charlie join -> kyc charlie -> charlie join again must revert
//         vm.prank(charlie);
//         subscriptionModule.paySubscription(charlie, address(0), CONTRIBUTION_AMOUNT, 5 * YEAR);

//         vm.warp(block.timestamp + 15 days);
//         vm.roll(block.number + 1);

//         vm.startPrank(charlie);
//         subscriptionModule.refund();
//         subscriptionModule.paySubscription(charlie, address(0), CONTRIBUTION_AMOUNT, 5 * YEAR);
//         vm.stopPrank();

//         vm.prank(admin);
//         kycModule.approveKYC(charlie, BM);

//         vm.prank(charlie);
//         vm.expectRevert(SubscriptionModule.SubscriptionModule__AlreadyJoined.selector);
//         subscriptionModule.paySubscription(charlie, address(0), CONTRIBUTION_AMOUNT, 5 * YEAR);

//         // Fourth check david join -> 14 days passes -> refund david -> david join -> david join again must revert
//         vm.prank(david);
//         subscriptionModule.paySubscription(david, address(0), CONTRIBUTION_AMOUNT, 5 * YEAR);

//         vm.warp(block.timestamp + 15 days);
//         vm.roll(block.number + 1);

//         vm.startPrank(david);
//         subscriptionModule.refund();
//         subscriptionModule.paySubscription(david, address(0), CONTRIBUTION_AMOUNT, 5 * YEAR);
//         vm.expectRevert(SubscriptionModule.SubscriptionModule__AlreadyJoined.selector);
//         subscriptionModule.paySubscription(david, address(0), CONTRIBUTION_AMOUNT, 5 * YEAR);
//         vm.stopPrank();
//     }
// }
