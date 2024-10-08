// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasureReserve} from "test/utils/TestDeployTakasureReserve.s.sol";
import {DeployConsumerMocks} from "test/utils/DeployConsumerMocks.s.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/takasure/core/TakasureReserve.sol";
import {JoinModule} from "contracts/takasure/modules/JoinModule.sol";
import {MembersModule} from "contracts/takasure/modules/MembersModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState, NewReserve} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract KycFlow_TakasurePoolTest is StdCheats, Test, SimulateDonResponse {
    TestDeployTakasureReserve deployer;
    DeployConsumerMocks mockDeployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    JoinModule joinModule;
    MembersModule membersModule;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address admin;
    address kycService;
    address takadao;
    address joinModuleAddress;
    address membersModuleAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant BENEFIT_MULTIPLIER_FROM_CONSUMER = 100046; // Mock respose
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new TestDeployTakasureReserve();
        (
            takasureReserveProxy,
            joinModuleAddress,
            membersModuleAddress,
            contributionTokenAddress,
            helperConfig
        ) = deployer.run();

        joinModule = JoinModule(joinModuleAddress);
        membersModule = MembersModule(membersModuleAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        kycService = config.kycProvider;
        takadao = config.takadaoOperator;

        mockDeployer = new DeployConsumerMocks();
        bmConsumerMock = mockDeployer.run();

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(membersModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(msg.sender);
        bmConsumerMock.setNewRequester(address(joinModuleAddress));

        vm.prank(takadao);
        joinModule.updateBmAddress();
    }

    /*//////////////////////////////////////////////////////////////
                            KYC FLOW::FLOW 1
    //////////////////////////////////////////////////////////////*/

    // This flow consist of the following steps:
    // 1. Set KYC status to true
    // 2. Join the pool

    /// @dev Test contribution amount is transferred to the contract
    function testJoinModule_KycFlow1() public {
        NewReserve memory reserve = takasureReserve.getReserveValues();
        uint256 memberIdBeforeKyc = reserve.memberIdCounter;

        vm.prank(admin);

        vm.expectEmit(true, true, true, true, address(joinModule));
        emit TakasureEvents.OnMemberCreated(memberIdBeforeKyc + 1, alice, 0, 0, 0, 5 * YEAR, 1);

        vm.expectEmit(true, false, false, false, address(joinModule));
        emit TakasureEvents.OnMemberKycVerified(memberIdBeforeKyc + 1, alice);
        joinModule.setKYCStatus(alice);

        reserve = takasureReserve.getReserveValues();
        uint256 memberIdAfterKyc = reserve.memberIdCounter;

        // member values only after KYC verification without joining the pool
        Member memory testMemberAfterKyc = takasureReserve.getMemberFromAddress(alice);

        console2.log("Member values after KYC verification without joining the pool");
        console2.log("Member ID", testMemberAfterKyc.memberId);
        console2.log("Benefit Multiplier", testMemberAfterKyc.benefitMultiplier);
        console2.log("Contribution", testMemberAfterKyc.contribution);
        console2.log("Total Service Fee", testMemberAfterKyc.totalServiceFee);
        console2.log("Wallet", testMemberAfterKyc.wallet);
        console2.log("Member State", uint8(testMemberAfterKyc.memberState));
        console2.log("KYC Verification", testMemberAfterKyc.isKYCVerified);

        // Check the values
        assertEq(memberIdBeforeKyc + 1, memberIdAfterKyc, "Member ID is not correct");
        assertEq(testMemberAfterKyc.memberId, memberIdAfterKyc, "Member ID is not correct");
        assertEq(testMemberAfterKyc.benefitMultiplier, 0, "Benefit Multiplier is not correct");
        assertEq(testMemberAfterKyc.contribution, 0, "Contribution is not correct");
        assertEq(testMemberAfterKyc.totalServiceFee, 0, "Total Service Fee is not correct");
        assertEq(testMemberAfterKyc.wallet, alice, "Wallet is not correct");
        assertEq(uint8(testMemberAfterKyc.memberState), 0, "Member State is not correct");
        assertEq(testMemberAfterKyc.isKYCVerified, true, "KYC Verification is not correct");
        console2.log("=====================================");

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        // Join the pool
        vm.prank(alice);

        vm.expectEmit(true, true, true, true, address(joinModule));
        emit TakasureEvents.OnMemberUpdated(
            memberIdAfterKyc,
            alice,
            BENEFIT_MULTIPLIER_FROM_CONSUMER,
            CONTRIBUTION_AMOUNT,
            ((CONTRIBUTION_AMOUNT * 22) / 100),
            5 * YEAR,
            1
        );

        vm.expectEmit(true, true, false, false, address(joinModule));
        emit TakasureEvents.OnMemberJoined(memberIdAfterKyc, alice);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);

        reserve = takasureReserve.getReserveValues();
        uint256 memberIdAfterJoin = reserve.memberIdCounter;

        // member values only after joining the pool
        Member memory testMemberAfterJoin = takasureReserve.getMemberFromAddress(alice);

        console2.log("Member values after joining the pool and KYC verification");
        console2.log("Member ID", testMemberAfterJoin.memberId);
        console2.log("Benefit Multiplier", testMemberAfterJoin.benefitMultiplier);
        console2.log("Contribution", testMemberAfterJoin.contribution);
        console2.log("Total Service Fee", testMemberAfterJoin.totalServiceFee);
        console2.log("Wallet", testMemberAfterJoin.wallet);
        console2.log("Member State", uint8(testMemberAfterJoin.memberState));
        console2.log("KYC Verification", testMemberAfterJoin.isKYCVerified);

        // Check the values
        assertEq(memberIdAfterKyc, memberIdAfterJoin, "Member ID is not correct");
        assertEq(testMemberAfterJoin.memberId, memberIdAfterJoin, "Member ID is not correct");
        assertEq(
            testMemberAfterJoin.benefitMultiplier,
            BENEFIT_MULTIPLIER_FROM_CONSUMER,
            "Benefit Multiplier is not correct"
        );
        assertEq(
            testMemberAfterJoin.contribution,
            CONTRIBUTION_AMOUNT,
            "Contribution is not correct"
        );
        assertEq(testMemberAfterJoin.wallet, alice, "Wallet is not correct");
        assertEq(uint8(testMemberAfterJoin.memberState), 1, "Member State is not correct");
        assertEq(testMemberAfterJoin.isKYCVerified, true, "KYC Verification is not correct");
    }

    /*//////////////////////////////////////////////////////////////
                            KYC FLOW::FLOW 2
    //////////////////////////////////////////////////////////////*/

    // This flow consist of the following steps:
    // 1. Join the pool
    // 2. Set KYC status to true

    /// @dev Test contribution amount is transferred to the contract
    function testJoinModule_KycFlow2() public {
        NewReserve memory reserve = takasureReserve.getReserveValues();
        uint256 memberIdBeforeJoin = reserve.memberIdCounter;

        // Join the pool
        vm.prank(alice);

        vm.expectEmit(true, true, true, true, address(joinModule));
        emit TakasureEvents.OnMemberCreated(
            memberIdBeforeJoin + 1,
            alice,
            0,
            CONTRIBUTION_AMOUNT,
            ((CONTRIBUTION_AMOUNT * 22) / 100),
            5 * YEAR,
            1
        );

        joinModule.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);

        reserve = takasureReserve.getReserveValues();
        uint256 memberIdAfterJoin = reserve.memberIdCounter;

        // member values only after joining the pool
        Member memory testMemberAfterJoin = takasureReserve.getMemberFromAddress(alice);

        console2.log("Member values after joining the pool and before KYC verification");
        console2.log("Member ID", testMemberAfterJoin.memberId);
        console2.log("Benefit Multiplier", testMemberAfterJoin.benefitMultiplier);
        console2.log("Contribution", testMemberAfterJoin.contribution);
        console2.log("Total Service Fee", testMemberAfterJoin.totalServiceFee);
        console2.log("Wallet", testMemberAfterJoin.wallet);
        console2.log("Member State", uint8(testMemberAfterJoin.memberState));
        console2.log("KYC Verification", testMemberAfterJoin.isKYCVerified);
        console2.log("=====================================");

        // Check the values
        assertEq(testMemberAfterJoin.memberId, memberIdAfterJoin, "Member ID is not correct");
        assertEq(testMemberAfterJoin.benefitMultiplier, 0, "Benefit Multiplier is not correct");
        assertEq(
            testMemberAfterJoin.contribution,
            CONTRIBUTION_AMOUNT,
            "Contribution is not correct"
        );
        assertEq(testMemberAfterJoin.wallet, alice, "Wallet is not correct");
        assertEq(uint8(testMemberAfterJoin.memberState), 0, "Member State is not correct");
        assertEq(testMemberAfterJoin.isKYCVerified, false, "KYC Verification is not correct");

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        // Set KYC status to true
        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(joinModule));
        emit TakasureEvents.OnMemberUpdated(
            memberIdAfterJoin,
            alice,
            BENEFIT_MULTIPLIER_FROM_CONSUMER,
            CONTRIBUTION_AMOUNT,
            ((CONTRIBUTION_AMOUNT * 22) / 100),
            5 * YEAR,
            1
        );

        vm.expectEmit(true, true, false, false, address(joinModule));
        emit TakasureEvents.OnMemberJoined(memberIdAfterJoin, alice);

        vm.expectEmit(true, false, false, false, address(joinModule));
        emit TakasureEvents.OnMemberKycVerified(memberIdAfterJoin, alice);
        joinModule.setKYCStatus(alice);

        reserve = takasureReserve.getReserveValues();
        uint256 memberIdAfterKyc = reserve.memberIdCounter;

        // member values only after KYC verification without joining the pool
        Member memory testMemberAfterKyc = takasureReserve.getMemberFromAddress(alice);

        console2.log("Member values after KYC verification and joining the pool");
        console2.log("Member ID", testMemberAfterKyc.memberId);
        console2.log("Benefit Multiplier", testMemberAfterKyc.benefitMultiplier);
        console2.log("Contribution", testMemberAfterKyc.contribution);
        console2.log("Total Service Fee", testMemberAfterKyc.totalServiceFee);
        console2.log("Wallet", testMemberAfterKyc.wallet);
        console2.log("Member State", uint8(testMemberAfterKyc.memberState));
        console2.log("KYC Verification", testMemberAfterKyc.isKYCVerified);

        // Check the values
        assertEq(testMemberAfterKyc.memberId, memberIdAfterKyc, "Member ID is not correct");
        assertEq(memberIdAfterJoin, memberIdAfterKyc, "Member ID is not correct");
        assertEq(
            testMemberAfterKyc.benefitMultiplier,
            BENEFIT_MULTIPLIER_FROM_CONSUMER,
            "Benefit Multiplier is not correct"
        );
        assertEq(
            testMemberAfterKyc.contribution,
            CONTRIBUTION_AMOUNT,
            "Contribution is not correct"
        );
        assertEq(testMemberAfterKyc.wallet, alice, "Wallet is not correct");
        assertEq(uint8(testMemberAfterKyc.memberState), 1, "Member State is not correct");
        assertEq(testMemberAfterKyc.isKYCVerified, true, "KYC Verification is not correct");
    }
}
