// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "deploy/02-DeployTokenAndPool.s.sol";
import {DeployConsumerMocks} from "deploy/00-DeployConsumerMocks.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumerMockSuccess} from "test/mocks/BenefitMultiplierConsumerMockSuccess.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";

contract KycFlow_TakasurePoolTest is StdCheats, Test {
    DeployTokenAndPool deployer;
    DeployConsumerMocks mockDeployer;
    TakasurePool takasurePool;
    ERC1967Proxy proxy;
    address contributionTokenAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public benefitMultiplierFromConsumer;
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new DeployTokenAndPool();
        (, proxy, , contributionTokenAddress, ) = deployer.run();

        mockDeployer = new DeployConsumerMocks();
        (
            ,
            ,
            BenefitMultiplierConsumerMockSuccess bmConsumerSuccess,
            address bmDeployer
        ) = mockDeployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.prank(alice);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);

        vm.prank(takasurePool.owner());
        takasurePool.setNewBenefitMultiplierConsumer(address(bmConsumerSuccess));

        vm.prank(bmDeployer);
        bmConsumerSuccess.setNewRequester(address(takasurePool));

        benefitMultiplierFromConsumer = bmConsumerSuccess.bm();
    }

    /*//////////////////////////////////////////////////////////////
                            KYC FLOW::FLOW 1
    //////////////////////////////////////////////////////////////*/

    // This flow consist of the following steps:
    // 1. Set KYC status to true
    // 2. Join the pool

    /// @dev Test contribution amount is transferred to the contract
    function testTakasurePool_KycFlow1() public {
        uint256 memberIdBeforeKyc = takasurePool.memberIdCounter();

        vm.prank(takasurePool.owner());

        vm.expectEmit(true, true, true, true, address(takasurePool));
        emit TakasureEvents.OnMemberCreated(memberIdBeforeKyc + 1, alice, 0, 0, 0, 5 * YEAR, 1);

        vm.expectEmit(true, false, false, false, address(takasurePool));
        emit TakasureEvents.OnMemberKycVerified(memberIdBeforeKyc + 1, alice);
        takasurePool.setKYCStatus(alice);

        uint256 memberIdAfterKyc = takasurePool.memberIdCounter();

        // member values only after KYC verification without joining the pool
        Member memory testMemberAfterKyc = takasurePool.getMemberFromAddress(alice);

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

        // Join the pool
        vm.prank(alice);

        vm.expectEmit(true, true, true, true, address(takasurePool));
        emit TakasureEvents.OnMemberUpdated(
            memberIdAfterKyc,
            alice,
            benefitMultiplierFromConsumer,
            CONTRIBUTION_AMOUNT,
            ((CONTRIBUTION_AMOUNT * 20) / 100),
            5 * YEAR,
            1
        );

        vm.expectEmit(true, true, false, false, address(takasurePool));
        emit TakasureEvents.OnMemberJoined(memberIdAfterKyc, alice);
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);

        uint256 memberIdAfterJoin = takasurePool.memberIdCounter();

        // member values only after joining the pool
        Member memory testMemberAfterJoin = takasurePool.getMemberFromAddress(alice);

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
            benefitMultiplierFromConsumer,
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
    function testTakasurePool_KycFlow2() public {
        uint256 memberIdBeforeJoin = takasurePool.memberIdCounter();

        // Join the pool
        vm.prank(alice);

        vm.expectEmit(true, true, true, true, address(takasurePool));
        emit TakasureEvents.OnMemberCreated(
            memberIdBeforeJoin + 1,
            alice,
            benefitMultiplierFromConsumer,
            CONTRIBUTION_AMOUNT,
            ((CONTRIBUTION_AMOUNT * 20) / 100),
            5 * YEAR,
            1
        );

        takasurePool.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);

        uint256 memberIdAfterJoin = takasurePool.memberIdCounter();

        // member values only after joining the pool
        Member memory testMemberAfterJoin = takasurePool.getMemberFromAddress(alice);

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
        assertEq(
            testMemberAfterJoin.benefitMultiplier,
            benefitMultiplierFromConsumer,
            "Benefit Multiplier is not correct"
        );
        assertEq(
            testMemberAfterJoin.contribution,
            CONTRIBUTION_AMOUNT,
            "Contribution is not correct"
        );
        assertEq(testMemberAfterJoin.wallet, alice, "Wallet is not correct");
        assertEq(uint8(testMemberAfterJoin.memberState), 0, "Member State is not correct");
        assertEq(testMemberAfterJoin.isKYCVerified, false, "KYC Verification is not correct");

        // Set KYC status to true
        vm.prank(takasurePool.owner());
        vm.expectEmit(true, true, true, true, address(takasurePool));
        emit TakasureEvents.OnMemberUpdated(
            memberIdAfterJoin,
            alice,
            benefitMultiplierFromConsumer,
            CONTRIBUTION_AMOUNT,
            ((CONTRIBUTION_AMOUNT * 20) / 100),
            5 * YEAR,
            1
        );

        vm.expectEmit(true, true, false, false, address(takasurePool));
        emit TakasureEvents.OnMemberJoined(memberIdAfterJoin, alice);

        vm.expectEmit(true, false, false, false, address(takasurePool));
        emit TakasureEvents.OnMemberKycVerified(memberIdAfterJoin, alice);
        takasurePool.setKYCStatus(alice);

        uint256 memberIdAfterKyc = takasurePool.memberIdCounter();

        // member values only after KYC verification without joining the pool
        Member memory testMemberAfterKyc = takasurePool.getMemberFromAddress(alice);

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
            benefitMultiplierFromConsumer,
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
