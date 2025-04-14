// // SPDX-License-Identifier: GNU GPLv3

// pragma solidity 0.8.28;

// import {Test, console2} from "forge-std/Test.sol";
// import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
// import {PrejoinModule} from "contracts/modules/PrejoinModule.sol";
// import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
// import {EntryModule} from "contracts/modules/EntryModule.sol";
// import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
// import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
// import {IUSDC} from "test/mocks/IUSDCmock.sol";
// import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

// contract DoubleJoinFromPrejoin_9681 is Test, SimulateDonResponse {
//     TestDeployProtocol deployer;
//     PrejoinModule prejoinModule;
//     TakasureReserve takasureReserve;
//     EntryModule entryModule;
//     BenefitMultiplierConsumerMock bmConsumerMock;
//     HelperConfig helperConfig;
//     IUSDC usdc;
//     address usdcAddress;
//     address prejoinModuleAddress;
//     address takasureReserveAddress;
//     address entryModuleAddress;
//     address takadao;
//     address daoAdmin;
//     address KYCProvider;
//     address referral = makeAddr("referral");
//     address member = makeAddr("member");
//     address notMember = makeAddr("notMember");
//     address child = makeAddr("child");
//     string tDaoName = "TheLifeDao";
//     uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
//     uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
//     uint8 public constant SERVICE_FEE_RATIO = 27;

//     event OnMemberJoined(uint256 indexed memberId, address indexed member);

//     function setUp() public {
//         // Deployer
//         deployer = new TestDeployProtocol();
//         // Deploy contracts
//         (
//             ,
//             bmConsumerMock,
//             takasureReserveAddress,
//             prejoinModuleAddress,
//             entryModuleAddress,
//             ,
//             ,
//             ,
//             usdcAddress,
//             ,
//             helperConfig
//         ) = deployer.run();

//         // Get config values
//         HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
//         takadao = config.takadaoOperator;
//         daoAdmin = config.daoMultisig;
//         KYCProvider = config.kycProvider;

//         // Assign implementations
//         prejoinModule = PrejoinModule(prejoinModuleAddress);
//         takasureReserve = TakasureReserve(takasureReserveAddress);
//         entryModule = EntryModule(entryModuleAddress);
//         usdc = IUSDC(usdcAddress);

//         // Config mocks
//         vm.startPrank(daoAdmin);
//         takasureReserve.setNewContributionToken(address(usdc));
//         takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));
//         vm.stopPrank();

//         vm.startPrank(bmConsumerMock.admin());
//         bmConsumerMock.setNewRequester(address(takasureReserve));
//         bmConsumerMock.setNewRequester(prejoinModuleAddress);
//         vm.stopPrank();

//         // Give and approve USDC
//         deal(address(usdc), referral, USDC_INITIAL_AMOUNT);
//         deal(address(usdc), child, USDC_INITIAL_AMOUNT);
//         deal(address(usdc), member, USDC_INITIAL_AMOUNT);

//         vm.prank(referral);
//         usdc.approve(address(prejoinModule), USDC_INITIAL_AMOUNT);
//         vm.prank(child);
//         usdc.approve(address(prejoinModule), USDC_INITIAL_AMOUNT);
//         vm.prank(member);
//         usdc.approve(address(takasureReserve), USDC_INITIAL_AMOUNT);
//     }

//     modifier createDao() {
//         vm.startPrank(daoAdmin);
//         prejoinModule.createDAO(tDaoName, true, true, 1743479999, 1e12, address(bmConsumerMock));
//         prejoinModule.setDAOName(tDaoName);
//         vm.stopPrank();
//         _;
//     }

//     modifier referralPrepays() {
//         vm.prank(referral);
//         prejoinModule.payContribution(CONTRIBUTION_AMOUNT, address(0));
//         _;
//     }

//     modifier KYCReferral() {
//         vm.prank(KYCProvider);
//         prejoinModule.setKYCStatus(referral);
//         _;
//     }

//     modifier referredPrepays() {
//         vm.prank(child);
//         prejoinModule.payContribution(CONTRIBUTION_AMOUNT, referral);

//         _;
//     }

//     modifier referredIsKYC() {
//         vm.prank(KYCProvider);
//         prejoinModule.setKYCStatus(child);
//         _;
//     }

//     function testJoinPoolDoubleJoinIssue()
//         public
//         createDao
//         referralPrepays
//         KYCReferral
//         referredPrepays
//         referredIsKYC
//     {
//         // We simulate a request before the KYC
//         _successResponse(address(bmConsumerMock));

//         (, , , , uint256 launchDate, , , , , , ) = prejoinModule.getDAOData();

//         vm.warp(launchDate + 1);
//         vm.roll(block.number + 1);

//         vm.startPrank(daoAdmin);
//         prejoinModule.launchDAO(address(takasureReserve), entryModuleAddress, true);
//         entryModule.updateBmAddress();
//         vm.stopPrank();

//         prejoinModule.joinDAO(child);

//         vm.expectRevert();
//         prejoinModule.joinDAO(child);
//     }
// }
