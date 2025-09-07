// // SPDX-License-Identifier: GPL-3.0

// pragma solidity 0.8.28;

// import {Test, console2} from "forge-std/Test.sol";
// import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
// import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
// import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
// import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
// import {KYCModule} from "contracts/modules/KYCModule.sol";
// import {MemberModule} from "contracts/modules/MemberModule.sol";
// import {StdCheats} from "forge-std/StdCheats.sol";
// import {Member, MemberState} from "contracts/types/TakasureTypes.sol";
// import {IUSDC} from "test/mocks/IUSDCmock.sol";
// import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";

// contract Cancel_MemberModuleTest is StdCheats, Test {
//     TestDeployProtocol deployer;
//     TakasureReserve takasureReserve;
//     HelperConfig helperConfig;
//     SubscriptionModule subscriptionModule;
//     KYCModule kycModule;
//     MemberModule memberModule;
//     address takasureReserveProxy;
//     address contributionTokenAddress;
//     address admin;
//     address kycService;
//     address takadao;
//     address subscriptionModuleAddress;
//     address kycModuleAddress;
//     address memberModuleAddress;
//     IUSDC usdc;
//     address public alice = makeAddr("alice");
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
//             memberModuleAddress,
//             ,
//             ,
//             contributionTokenAddress,
//             ,
//             helperConfig
//         ) = deployer.run();

//         subscriptionModule = SubscriptionModule(subscriptionModuleAddress);
//         kycModule = KYCModule(kycModuleAddress);
//         memberModule = MemberModule(memberModuleAddress);

//         HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

//         admin = config.daoMultisig;
//         kycService = config.kycProvider;
//         takadao = config.takadaoOperator;

//         takasureReserve = TakasureReserve(takasureReserveProxy);
//         usdc = IUSDC(contributionTokenAddress);

//         // For easier testing there is a minimal USDC mock contract without restrictions
//         deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

//         vm.startPrank(alice);
//         usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
//         usdc.approve(address(memberModule), USDC_INITIAL_AMOUNT);

//         subscriptionModule.paySubscription(alice, address(0), CONTRIBUTION_AMOUNT, 5 * YEAR);
//         vm.stopPrank();

//         vm.prank(admin);
//         kycModule.approveKYC(alice, BM);

//         vm.warp(block.timestamp + YEAR + 31 days);
//         vm.roll(block.number + 1);

//         memberModule.defaultMember(alice);
//     }

//     function testMemberModule_cancelMembershipThroughModule() public {
//         Member memory Alice = takasureReserve.getMemberFromAddress(alice);
//         assert(Alice.memberState == MemberState.Defaulted);

//         vm.expectEmit(true, true, false, false, address(memberModule));
//         emit TakasureEvents.OnMemberCanceled(Alice.memberId, alice);
//         memberModule.cancelMembership(alice);

//         Alice = takasureReserve.getMemberFromAddress(alice);
//         assert(Alice.memberState == MemberState.Canceled);
//     }

//     function testMemberModule_cancelMembershipThroughRouter() public {
//         Member memory Alice = takasureReserve.getMemberFromAddress(alice);
//         assert(Alice.memberState == MemberState.Defaulted);

//         vm.expectEmit(true, true, false, false, address(memberModule));
//         emit TakasureEvents.OnMemberCanceled(Alice.memberId, alice);
//         memberModule.cancelMembership(alice);

//         Alice = takasureReserve.getMemberFromAddress(alice);
//         assert(Alice.memberState == MemberState.Canceled);
//     }
// }
