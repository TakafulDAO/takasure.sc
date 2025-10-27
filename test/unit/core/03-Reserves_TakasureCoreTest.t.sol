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
// import {Reserve} from "contracts/types/TakasureTypes.sol";
// import {IUSDC} from "test/mocks/IUSDCmock.sol";

// contract Reserves_TakasureCoreTest is StdCheats, Test {
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
//     address public alice = makeAddr("alice");
//     uint256 public constant USDC_INITIAL_AMOUNT = 1000e6; // 1000 USDC
//     uint256 public constant CONTRIBUTION_AMOUNT = 225e6; // 225 USDC
//     uint256 public constant DEPOSITED_ON_SUBSCRIPTION = 25e6;
//     uint256 public constant YEAR = 365 days;

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

//         // For easier testing there is a minimal USDC mock contract without restrictions
//         deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

//         vm.startPrank(alice);
//         usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
//         usdc.approve(address(lifeBenefitModule), USDC_INITIAL_AMOUNT);
//         vm.stopPrank();

//         vm.prank(couponRedeemer);
//         subscriptionModule.paySubscriptionOnBehalfOf(alice, address(0), 0, block.timestamp);

//         vm.prank(kycProvider);
//         kycModule.approveKYC(alice);
//     }

//     /*//////////////////////////////////////////////////////////////
//                     JOIN POOL::UPDATE RESERVES
//     //////////////////////////////////////////////////////////////*/

//     /// @dev Test fund and claim reserves are calculated correctly
//     function testTakasureCore_fundAndClaimReserves() public {
//         vm.prank(couponRedeemer);
//         lifeBenefitModule.joinBenefitOnBehalfOf(alice, CONTRIBUTION_AMOUNT, (5 * YEAR), 0);

//         Reserve memory reserve = takasureReserve.getReserveValues();
//         uint256 reserveRatio = reserve.initialReserveRatio;
//         uint256 claimReserve = reserve.totalClaimReserve;
//         uint256 fundReserve = reserve.totalFundReserve;
//         uint8 serviceFee = reserve.serviceFee;
//         uint8 fundMarketExpendsShare = reserve.fundMarketExpendsAddShare;

//         uint256 fee = (CONTRIBUTION_AMOUNT * serviceFee) / 100; // 225USDC * 27% = 60.75USDC

//         uint256 deposited = CONTRIBUTION_AMOUNT - fee; // 225USDC - 60.75USDC = 164.25USDC

//         uint256 toFundReserveBeforeExpends = (deposited * reserveRatio) / 100; // 164.25USDC * 40% = 65.7USDC
//         uint256 marketExpends = (toFundReserveBeforeExpends * fundMarketExpendsShare) / 100; // 65.7USDC * 20% = 13.14USDC
//         uint256 expectedClaimReserve = deposited - toFundReserveBeforeExpends; // 164.25USDC - 65.7USDC = 98.55USDC
//         uint256 expectedFundReserve = toFundReserveBeforeExpends - marketExpends;
//         assertEq(claimReserve, 98_550_000);
//         assertEq(fundReserve, 52_560_000);
//         assertEq(claimReserve, expectedClaimReserve);
//         assertEq(fundReserve, expectedFundReserve);
//     }

//     /*//////////////////////////////////////////////////////////////
//                     JOIN POOL::CASH LAST 12 MONTHS
//     //////////////////////////////////////////////////////////////*/

//     /// @dev Cash last 12 months less than a month
//     function testTakasureCore_cashLessThanMonth() public {
//         address[50] memory lotOfUsers;
//         for (uint256 i; i < lotOfUsers.length; i++) {
//             lotOfUsers[i] = makeAddr(vm.toString(i));
//             _subscribe(lotOfUsers[i]);
//         }

//         // Each day 10 users will join with the contribution amount
//         // First day
//         for (uint256 i; i < 10; i++) {
//             _joinBenefit(lotOfUsers[i]);
//         }

//         vm.warp(block.timestamp + 1 days);
//         vm.roll(block.number + 1);

//         // Second day
//         for (uint256 i = 10; i < 20; i++) {
//             _joinBenefit(lotOfUsers[i]);
//         }

//         vm.warp(block.timestamp + 1 days);
//         vm.roll(block.number + 1);

//         // Third day
//         for (uint256 i = 20; i < 30; i++) {
//             _joinBenefit(lotOfUsers[i]);
//         }

//         vm.warp(block.timestamp + 1 days);
//         vm.roll(block.number + 1);

//         // Fourth day
//         for (uint256 i = 30; i < 40; i++) {
//             _joinBenefit(lotOfUsers[i]);
//         }

//         vm.warp(block.timestamp + 1 days);
//         vm.roll(block.number + 1);

//         // Fifth day
//         for (uint256 i = 40; i < 50; i++) {
//             _joinBenefit(lotOfUsers[i]);
//         }

//         uint256 cash = takasureReserve.getCashLast12Months();

//         Reserve memory reserve = takasureReserve.getReserveValues();
//         uint256 totalMembers = reserve.memberIdCounter; // 50 members
//         uint8 serviceFee = reserve.serviceFee; // 27%
//         uint256 depositedByEach = (CONTRIBUTION_AMOUNT + DEPOSITED_ON_SUBSCRIPTION) -
//             (((CONTRIBUTION_AMOUNT + DEPOSITED_ON_SUBSCRIPTION) * serviceFee) / 100); // (225 + 25) - ((225 + 25) * 27%) = 182.5USDC
//         uint256 totalDeposited = totalMembers * depositedByEach; // 50 * 182.5USDC = 9125USDC
//         assertEq(cash, totalDeposited);
//     }

//     /// @dev Cash last 12 months more than a month less than a year
//     function testTakasureCore_cashMoreThanMonthLessThanYear() public {
//         address[78] memory lotOfUsers;
//         for (uint256 i; i < lotOfUsers.length; i++) {
//             lotOfUsers[i] = makeAddr(vm.toString(i));
//             _subscribe(lotOfUsers[i]);
//         }

//         // Test three months two days

//         // First month 30 people joins
//         // 250USDC - fee = 182.5USDC
//         // 182.5 * 30 = 5475USDC
//         for (uint256 i; i < 30; i++) {
//             _joinBenefit(lotOfUsers[i]);
//         }

//         vm.warp(block.timestamp + 31 days);
//         vm.roll(block.number + 1);

//         // Second 10 people joins
//         // 182.5 * 10 = 1825USDC + 5475USDC = 7300USDC
//         for (uint256 i = 30; i < 40; i++) {
//             _joinBenefit(lotOfUsers[i]);
//         }

//         vm.warp(block.timestamp + 31 days);
//         vm.roll(block.number + 1);

//         // Third month first day 15 people joins
//         // 182.5 * 15 = 2737.5USDC + 7300USDC = 10037.5USDC
//         for (uint256 i = 40; i < 55; i++) {
//             _joinBenefit(lotOfUsers[i]);
//         }

//         vm.warp(block.timestamp + 1 days);
//         vm.roll(block.number + 1);

//         // Third month second day 23 people joins
//         // 182.5 * 23 = 4197.5USDC + 10037.5USDC = 14235USDC
//         for (uint256 i = 55; i < 78; i++) {
//             _joinBenefit(lotOfUsers[i]);
//         }

//         uint256 cash = takasureReserve.getCashLast12Months();

//         Reserve memory reserve = takasureReserve.getReserveValues();

//         uint256 totalMembers = reserve.memberIdCounter;
//         uint8 serviceFee = reserve.serviceFee;
//         uint256 depositedByEach = (CONTRIBUTION_AMOUNT + DEPOSITED_ON_SUBSCRIPTION) -
//             (((CONTRIBUTION_AMOUNT + DEPOSITED_ON_SUBSCRIPTION) * serviceFee) / 100);
//         uint256 totalDeposited = totalMembers * depositedByEach;

//         assertEq(cash, totalDeposited);
//     }

//     /// @dev Cash last 12 months more than a  year
//     function testTakasureCore_cashMoreThanYear() public {
//         uint256 cash;
//         address[202] memory lotOfUsers;
//         for (uint256 i; i < lotOfUsers.length; i++) {
//             lotOfUsers[i] = makeAddr(vm.toString(i));
//             _subscribe(lotOfUsers[i]);
//         }

//         // Months 1, 2 and 3, one new member joins daily
//         // Month 1 182,5USDC * 30 = 5475USDC
//         // Month 2 182,5USDC * 30 = 5475USDC
//         // Month 3 182,5USDC * 30 = 5475USDC
//         for (uint256 i; i < 90; i++) {
//             _joinBenefit(lotOfUsers[i]);

//             vm.warp(block.timestamp + 1 days);
//             vm.roll(block.number + 1);
//         }

//         // Months 4 to 12, 10 new members join monthly
//         // Month 4 182,5USDC * 10 = 1825USDC
//         // Month 5 182,5USDC * 10 = 1825USDC
//         // Month 6 182,5USDC * 10 = 1825USDC
//         // Month 7 182,5USDC * 10 = 1825USDC
//         // Month 8 182,5USDC * 10 = 1825USDC
//         // Month 9 182,5USDC * 10 = 1825USDC
//         // Month 10 182,5USDC * 10 = 1825USDC
//         // Month 11 182,5USDC * 10 = 1825USDC
//         // Month 12 182,5USDC * 10 = 1825USDC
//         for (uint256 i = 90; i < 180; i++) {
//             _joinBenefit(lotOfUsers[i]);

//             // End of the month
//             if (
//                 i == 99 ||
//                 i == 109 ||
//                 i == 119 ||
//                 i == 129 ||
//                 i == 139 ||
//                 i == 149 ||
//                 i == 159 ||
//                 i == 169 ||
//                 i == 179
//             ) {
//                 vm.warp(block.timestamp + 30 days);
//                 vm.roll(block.number + 1);
//             }
//         }

//         // Month 1 take 29 days => Total 182,5 * 29 = 5292.5USDC
//         // Months 2 to 12 take all => Total (5475 * 2) + (1825 * 9) = 10950USDC + 16425USDC = 27375USDC
//         // Month 13 0USDC
//         // Total 5292.5USDC + 27375USDC = 32667.5USDC

//         cash = takasureReserve.getCashLast12Months();
//         assertEq(cash, 326675e5);

//         // Thirteenth month 10 people joins
//         for (uint256 i = 180; i < 190; i++) {
//             _joinBenefit(lotOfUsers[i]);
//         }

//         // Month 1 take 29 days
//         // Month 2 to 13 take all

//         cash = takasureReserve.getCashLast12Months();
//         assertEq(cash, 344925e5);

//         vm.warp(block.timestamp + 30 days);
//         vm.roll(block.number + 1);

//         // Month 1 Should not count
//         // Month 2 take 29 days
//         // Month 3 to 13 take all

//         cash = takasureReserve.getCashLast12Months();
//         assertEq(cash, 290175e5);

//         // Fourteenth month 10 people joins
//         for (uint256 i = 190; i < 200; i++) {
//             _joinBenefit(lotOfUsers[i]);
//         }

//         // Month 1 should not count
//         // Month 2 take 29 days
//         // Month 3 to 14 take all

//         cash = takasureReserve.getCashLast12Months();
//         assertEq(cash, 308425e5);

//         vm.warp(block.timestamp + 30 days);
//         vm.roll(block.number + 1);

//         // Month 1 and 2 should not count
//         // Month 3 take 29 days
//         // Month 4 to 14 take all
//         // Month 15 0USDC

//         cash = takasureReserve.getCashLast12Months();
//         assertEq(cash, 253675e5);

//         // Last 2 days 2 people joins
//         for (uint256 i = 200; i < 202; i++) {
//             _joinBenefit(lotOfUsers[i]);

//             vm.warp(block.timestamp + 1 days);
//             vm.roll(block.number + 1);
//         }

//         // Month 1 and 2 should not count
//         // Month 3 take 27 days
//         // Month 4 to 15 take all

//         cash = takasureReserve.getCashLast12Months();

//         assertEq(cash, 253675e5);

//         // If no one joins for the next 12 months, the cash should be 0
//         // As the months are counted with 30 days, the 12 months should be 360 days
//         // 1 day after the year should be only 20USDC
//         vm.warp(block.timestamp + 359 days);
//         vm.roll(block.number + 1);

//         cash = takasureReserve.getCashLast12Months();
//         assertEq(cash, 0);
//     }

//     function _subscribe(address _newJoiner) public {
//         deal(address(usdc), _newJoiner, USDC_INITIAL_AMOUNT);

//         vm.startPrank(_newJoiner);
//         usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
//         usdc.approve(address(lifeBenefitModule), USDC_INITIAL_AMOUNT);
//         vm.stopPrank();

//         vm.prank(couponRedeemer);
//         subscriptionModule.paySubscriptionOnBehalfOf(_newJoiner, address(0), 0, block.timestamp);

//         vm.prank(kycProvider);
//         kycModule.approveKYC(_newJoiner);
//     }

//     function _joinBenefit(address _newJoiner) public {
//         vm.prank(couponRedeemer);
//         lifeBenefitModule.joinBenefitOnBehalfOf(_newJoiner, CONTRIBUTION_AMOUNT, (5 * YEAR), 0);
//     }
// }
