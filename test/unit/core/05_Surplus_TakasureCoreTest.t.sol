// // SPDX-License-Identifier: GPL-3.0

// pragma solidity 0.8.28;

// import {Test, console2} from "forge-std/Test.sol";
// import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
// import {DeployModules} from "test/utils/03-DeployModules.s.sol";
// import {DeployReserve} from "test/utils/02-DeployReserve.s.sol";
// import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
// import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
// import {AddressManager} from "contracts/managers/AddressManager.sol";
// import {ModuleManager} from "contracts/managers/ModuleManager.sol";
// import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
// import {BenefitModule} from "contracts/modules/BenefitModule.sol";
// import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
// import {KYCModule} from "contracts/modules/KYCModule.sol";
// import {StdCheats} from "forge-std/StdCheats.sol";
// import {BenefitMember, Reserve} from "contracts/types/TakasureTypes.sol";
// import {IUSDC} from "test/mocks/IUSDCmock.sol";
// import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";

// contract Surplus_TakasureCoreTest is StdCheats, Test {
//     DeployManagers managersDeployer;
//     DeployModules moduleDeployer;
//     AddAddressesAndRoles addressesAndRoles;
//     DeployReserve deployer;
//     TakasureReserve takasureReserve;
//     BenefitModule lifeBenefitModule;
//     SubscriptionModule subscriptionModule;
//     KYCModule kycModule;
//     address kycProvider;
//     address couponRedeemer;
//     address takadao;
//     IUSDC usdc;
//     uint256 public constant USDC_INITIAL_AMOUNT = 1000e6; // 1000 USDC
//     uint256 public constant EXTRA_CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
//     uint256 public constant DEPOSITED_ON_SUBSCRIPTION = 25e6;
//     uint256 public constant YEAR = 365 days;

//     // Users
//     address public alice = makeAddr("alice");
//     address public bob = makeAddr("bob");
//     address public charlie = makeAddr("charlie");
//     address public david = makeAddr("david");
//     address public erin = makeAddr("erin");
//     address public frank = makeAddr("frank");

//     function setUp() public {
//         managersDeployer = new DeployManagers();
//         addressesAndRoles = new AddAddressesAndRoles();
//         moduleDeployer = new DeployModules();
//         deployer = new DeployReserve();

//         (
//             HelperConfig.NetworkConfig memory config,
//             AddressManager addressManager,
//             ModuleManager moduleManager
//         ) = managersDeployer.run();

//         (takadao, , kycProvider, couponRedeemer, , , ) = addressesAndRoles.run(
//             addressManager,
//             config,
//             address(moduleManager)
//         );

//         (lifeBenefitModule, , kycModule, , , , , subscriptionModule) = moduleDeployer.run(
//             addressManager
//         );

//         takasureReserve = deployer.run(config, addressManager);

//         usdc = IUSDC(config.contributionToken);

//         _tokensTo(alice);
//         _tokensTo(bob);
//         _tokensTo(charlie);
//         _tokensTo(david);
//         _tokensTo(erin);
//         _tokensTo(frank);
//     }

//     function testTakasureCore_surplus() public {
//         // Alice joins in day 1
//         _join(alice, 1);
//         Reserve memory reserve = takasureReserve.getReserveValues();
//         uint256 ECRes = reserve.ECRes;
//         uint256 UCRes = reserve.UCRes;
//         uint256 surplus = reserve.surplus;
//         BenefitMember memory ALICE = takasureReserve.getMemberFromAddress(alice);
//         assertEq(ALICE.lastEcr, 0);
//         assertEq(ALICE.lastUcr, 0);
//         assertEq(ECRes, 0);
//         assertEq(UCRes, 0);
//         assertEq(surplus, 0);

//         // Bob joins in day 1
//         _join(bob, 3);
//         reserve = takasureReserve.getReserveValues();
//         ECRes = reserve.ECRes;
//         UCRes = reserve.UCRes;
//         surplus = reserve.surplus;
//         ALICE = takasureReserve.getMemberFromAddress(alice);
//         BenefitMember memory BOB = takasureReserve.getMemberFromAddress(bob);
//         assertEq(ALICE.lastEcr, 10_950_000);
//         assertEq(ALICE.lastUcr, 0);
//         assertEq(BOB.lastEcr, 0);
//         assertEq(BOB.lastUcr, 0);
//         assertEq(ECRes, 10_950_000);
//         assertEq(UCRes, 0);
//         assertEq(surplus, 10_950_000);

//         // 1 day passes
//         vm.warp(block.timestamp + 1 days);
//         vm.roll(block.number + 1);

//         // Charlie joins in day 2
//         _join(charlie, 10);
//         reserve = takasureReserve.getReserveValues();
//         ECRes = reserve.ECRes;
//         UCRes = reserve.UCRes;
//         surplus = reserve.surplus;
//         ALICE = takasureReserve.getMemberFromAddress(alice);
//         BOB = takasureReserve.getMemberFromAddress(bob);
//         BenefitMember memory CHARLIE = takasureReserve.getMemberFromAddress(charlie);

//         assertEq(ALICE.lastEcr, 10_920_000);
//         assertEq(ALICE.lastUcr, 30_000);
//         assertEq(BOB.lastEcr, 28_392_000);
//         assertEq(BOB.lastUcr, 78_000);
//         assertEq(CHARLIE.lastEcr, 0);
//         assertEq(CHARLIE.lastUcr, 0);
//         assertEq(ECRes, 39_312_000);
//         assertEq(UCRes, 108_000);
//         assertEq(surplus, 39_312_000);

//         // 1 day passes
//         vm.warp(block.timestamp + 1 days);
//         vm.roll(block.number + 1);

//         // David joins in day 3
//         _join(david, 5);
//         reserve = takasureReserve.getReserveValues();
//         ECRes = reserve.ECRes;
//         UCRes = reserve.UCRes;
//         surplus = reserve.surplus;
//         ALICE = takasureReserve.getMemberFromAddress(alice);
//         BOB = takasureReserve.getMemberFromAddress(bob);
//         CHARLIE = takasureReserve.getMemberFromAddress(charlie);
//         BenefitMember memory DAVID = takasureReserve.getMemberFromAddress(david);
//         assertEq(ALICE.lastEcr, 10_890_000);
//         assertEq(ALICE.lastUcr, 60_000);
//         assertEq(BOB.lastEcr, 28_314_000);
//         assertEq(BOB.lastUcr, 156_000);
//         assertEq(CHARLIE.lastEcr, 105_560_000);
//         assertEq(CHARLIE.lastUcr, 290_000);
//         assertEq(DAVID.lastEcr, 0);
//         assertEq(DAVID.lastUcr, 0);
//         assertEq(ECRes, 144_764_000);
//         assertEq(UCRes, 506_000);
//         assertEq(surplus, 144_764_000);

//         // 1 day passes
//         vm.warp(block.timestamp + 1 days);
//         vm.roll(block.number + 1);

//         // Erin joins in day 4
//         _join(erin, 2);
//         reserve = takasureReserve.getReserveValues();
//         ECRes = reserve.ECRes;
//         UCRes = reserve.UCRes;
//         surplus = reserve.surplus;
//         ALICE = takasureReserve.getMemberFromAddress(alice);
//         BOB = takasureReserve.getMemberFromAddress(bob);
//         CHARLIE = takasureReserve.getMemberFromAddress(charlie);
//         DAVID = takasureReserve.getMemberFromAddress(david);
//         BenefitMember memory ERIN = takasureReserve.getMemberFromAddress(erin);
//         assertEq(ALICE.lastEcr, 10_860_000);
//         assertEq(ALICE.lastUcr, 90_000);
//         assertEq(BOB.lastEcr, 28_236_000);
//         assertEq(BOB.lastUcr, 234_000);
//         assertEq(CHARLIE.lastEcr, 105_270_000);
//         assertEq(CHARLIE.lastUcr, 580_000);
//         assertEq(DAVID.lastEcr, 50_960_000);
//         assertEq(DAVID.lastUcr, 140_000);
//         assertEq(ERIN.lastEcr, 0);
//         assertEq(ERIN.lastUcr, 0);
//         assertEq(ECRes, 195_326_000);
//         assertEq(UCRes, 1_044_000);
//         assertEq(surplus, 195_326_000);

//         // 1 day passes
//         vm.warp(block.timestamp + 1 days);
//         vm.roll(block.number + 1);

//         // Frank joins in day 5
//         _join(frank, 7);
//         reserve = takasureReserve.getReserveValues();
//         ECRes = reserve.ECRes;
//         UCRes = reserve.UCRes;
//         surplus = reserve.surplus;
//         ALICE = takasureReserve.getMemberFromAddress(alice);
//         BOB = takasureReserve.getMemberFromAddress(bob);
//         CHARLIE = takasureReserve.getMemberFromAddress(charlie);
//         DAVID = takasureReserve.getMemberFromAddress(david);
//         ERIN = takasureReserve.getMemberFromAddress(erin);
//         BenefitMember memory FRANK = takasureReserve.getMemberFromAddress(frank);
//         assertEq(ALICE.lastEcr, 10_830_000);
//         assertEq(ALICE.lastUcr, 120_000);
//         assertEq(BOB.lastEcr, 28_158_000);
//         assertEq(BOB.lastUcr, 312_000);
//         assertEq(CHARLIE.lastEcr, 104_980_000);
//         assertEq(CHARLIE.lastUcr, 870_000);
//         assertEq(DAVID.lastEcr, 50_820_000);
//         assertEq(DAVID.lastUcr, 280_000);
//         assertEq(ERIN.lastEcr, 20_384_000);
//         assertEq(ERIN.lastUcr, 56_000);
//         assertEq(FRANK.lastEcr, 0);
//         assertEq(FRANK.lastUcr, 0);
//         assertEq(ECRes, 215_172_000);
//         assertEq(UCRes, 1_638_000);
//         assertEq(surplus, 215_172_000);
//     }

//     function _tokensTo(address _user) internal {
//         deal(address(usdc), _user, USDC_INITIAL_AMOUNT);
//         vm.startPrank(_user);
//         usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
//         usdc.approve(address(lifeBenefitModule), USDC_INITIAL_AMOUNT);
//         vm.stopPrank();
//     }

//     function _join(address _user, uint256 timesContributionAmount) internal {
//         vm.prank(couponRedeemer);
//         subscriptionModule.paySubscriptionOnBehalfOf(_user, address(0), 0, block.timestamp);

//         vm.prank(kycProvider);
//         kycModule.approveKYC(_user);

//         vm.prank(couponRedeemer);
//         lifeBenefitModule.joinBenefitOnBehalfOf(
//             _user,
//             timesContributionAmount * EXTRA_CONTRIBUTION_AMOUNT,
//             (5 * YEAR),
//             0
//         );
//     }
// }
