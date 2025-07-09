// // SPDX-License-Identifier: GPL-3.0

// pragma solidity 0.8.28;

// import {Test, console2} from "forge-std/Test.sol";
// import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
// import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
// import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
// import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
// import {KYCModule} from "contracts/modules/KYCModule.sol";
// import {StdCheats} from "forge-std/StdCheats.sol";
// import {Member, Reserve} from "contracts/types/TakasureTypes.sol";
// import {IUSDC} from "test/mocks/IUSDCmock.sol";
// import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";

// contract KycFlow_KYCModuleTest is StdCheats, Test {
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
//     uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
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

//         vm.startPrank(alice);
//         usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
//         vm.stopPrank();
//     }

//     /// @dev Test contribution amount is transferred to the contract
//     function testKYCModule_KycFlow() public {
//         Reserve memory reserve = takasureReserve.getReserveValues();
//         uint256 memberIdBeforeJoin = reserve.memberIdCounter;

//         // Join the pool
//         vm.prank(alice);

//         vm.expectEmit(true, true, true, true, address(subscriptionModule));
//         emit TakasureEvents.OnMemberCreated(
//             memberIdBeforeJoin + 1,
//             alice,
//             CONTRIBUTION_AMOUNT,
//             ((CONTRIBUTION_AMOUNT * 27) / 100),
//             5 * YEAR,
//             1,
//             false
//         );

//         subscriptionModule.paySubscription(alice, address(0), CONTRIBUTION_AMOUNT, 5 * YEAR);

//         reserve = takasureReserve.getReserveValues();
//         uint256 memberIdAfterJoin = reserve.memberIdCounter;

//         // member values only after joining the pool
//         Member memory testMemberAfterJoin = takasureReserve.getMemberFromAddress(alice);

//         console2.log("Member values after joining the pool and before KYC verification");
//         console2.log("Member ID", testMemberAfterJoin.memberId);
//         console2.log("Benefit Multiplier", testMemberAfterJoin.benefitMultiplier);
//         console2.log("Contribution", testMemberAfterJoin.contribution);
//         console2.log("Total Service Fee", testMemberAfterJoin.totalServiceFee);
//         console2.log("Wallet", testMemberAfterJoin.wallet);
//         console2.log("Member State", uint8(testMemberAfterJoin.memberState));
//         console2.log("KYC Verification", testMemberAfterJoin.isKYCVerified);
//         console2.log("=====================================");

//         // Check the values
//         assertEq(testMemberAfterJoin.memberId, memberIdAfterJoin, "Member ID is not correct");
//         assertEq(testMemberAfterJoin.benefitMultiplier, 0, "Benefit Multiplier is not correct");
//         assertEq(
//             testMemberAfterJoin.contribution,
//             CONTRIBUTION_AMOUNT,
//             "Contribution is not correct"
//         );
//         assertEq(testMemberAfterJoin.wallet, alice, "Wallet is not correct");
//         assertEq(uint8(testMemberAfterJoin.memberState), 0, "Member State is not correct");
//         assertEq(testMemberAfterJoin.isKYCVerified, false, "KYC Verification is not correct");

//         // Set KYC status to true
//         vm.prank(admin);
//         vm.expectEmit(true, false, false, false, address(kycModule));
//         emit TakasureEvents.OnMemberKycVerified(memberIdAfterJoin, alice);

//         vm.expectEmit(true, true, false, false, address(kycModule));
//         emit TakasureEvents.OnMemberJoined(memberIdAfterJoin, alice);

//         kycModule.approveKYC(alice, BM);

//         reserve = takasureReserve.getReserveValues();
//         uint256 memberIdAfterKyc = reserve.memberIdCounter;

//         // member values only after KYC verification without joining the pool
//         Member memory testMemberAfterKyc = takasureReserve.getMemberFromAddress(alice);

//         console2.log("Member values after KYC verification and joining the pool");
//         console2.log("Member ID", testMemberAfterKyc.memberId);
//         console2.log("Benefit Multiplier", testMemberAfterKyc.benefitMultiplier);
//         console2.log("Contribution", testMemberAfterKyc.contribution);
//         console2.log("Total Service Fee", testMemberAfterKyc.totalServiceFee);
//         console2.log("Wallet", testMemberAfterKyc.wallet);
//         console2.log("Member State", uint8(testMemberAfterKyc.memberState));
//         console2.log("KYC Verification", testMemberAfterKyc.isKYCVerified);

//         // Check the values
//         assertEq(testMemberAfterKyc.memberId, memberIdAfterKyc, "Member ID is not correct");
//         assertEq(memberIdAfterJoin, memberIdAfterKyc, "Member ID is not correct");
//         assertEq(testMemberAfterKyc.benefitMultiplier, BM, "Benefit Multiplier is not correct");
//         assertEq(
//             testMemberAfterKyc.contribution,
//             CONTRIBUTION_AMOUNT,
//             "Contribution is not correct"
//         );
//         assertEq(testMemberAfterKyc.wallet, alice, "Wallet is not correct");
//         assertEq(uint8(testMemberAfterKyc.memberState), 1, "Member State is not correct");
//         assertEq(testMemberAfterKyc.isKYCVerified, true, "KYC Verification is not correct");
//     }
// }
