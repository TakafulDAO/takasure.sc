// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "../../../../scripts/foundry-deploy/DeployTokenAndPool.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "../../../../contracts/takasure/TakasurePool.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState} from "../../../../contracts/types/TakasureTypes.sol";
import {IUSDC} from "../../../../contracts/mocks/IUSDCmock.sol";

contract KycFlow_TakasurePoolTest is StdCheats, Test {
    DeployTokenAndPool deployer;
    TakasurePool takasurePool;
    ERC1967Proxy proxy;
    address contributionTokenAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant BENEFIT_MULTIPLIER = 0;
    uint256 public constant YEAR = 365 days;

    event MemberJoined(address indexed member, uint256 indexed contributionAmount);

    function setUp() public {
        deployer = new DeployTokenAndPool();
        (, proxy, , contributionTokenAddress, ) = deployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.prank(alice);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
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
        takasurePool.setKYCStatus(alice);

        uint256 memberIdAfterKyc = takasurePool.memberIdCounter();

        // member values only after KYC verification without joining the pool
        Member memory testMemberAfterKyc = takasurePool.getMemberFromAddress(alice);

        // Check the values
        assertEq(memberIdBeforeKyc + 1, memberIdAfterKyc, "Member ID is not correct");
        assertEq(testMemberAfterKyc.memberId, memberIdAfterKyc, "Member ID is not correct");
        assertEq(testMemberAfterKyc.benefitMultiplier, 0, "Benefit Multiplier is not correct");
        assertEq(testMemberAfterKyc.contribution, 0, "Contribution is not correct");
        assertEq(testMemberAfterKyc.totalWakalaFee, 0, "Total Wakala Fee is not correct");
        assertEq(testMemberAfterKyc.wallet, alice, "Wallet is not correct");
        assertEq(uint8(testMemberAfterKyc.memberState), 0, "Member State is not correct");
        assertEq(testMemberAfterKyc.isKYCVerified, true, "KYC Verification is not correct");

        // Join the pool
        vm.prank(alice);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, 5 * YEAR);

        uint256 memberIdAfterJoin = takasurePool.memberIdCounter();

        // member values only after joining the pool
        Member memory testMemberAfterJoin = takasurePool.getMemberFromAddress(alice);

        // Check the values
        assertEq(memberIdAfterKyc, memberIdAfterJoin, "Member ID is not correct");
        assertEq(testMemberAfterJoin.memberId, memberIdAfterJoin, "Member ID is not correct");
        assertEq(
            testMemberAfterJoin.benefitMultiplier,
            BENEFIT_MULTIPLIER,
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
        // Join the pool
        vm.prank(alice);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, 5 * YEAR);

        uint256 memberIdAfterJoin = takasurePool.memberIdCounter();

        // member values only after joining the pool
        Member memory testMemberAfterJoin = takasurePool.getMemberFromAddress(alice);

        // Check the values
        assertEq(testMemberAfterJoin.memberId, memberIdAfterJoin, "Member ID is not correct");
        assertEq(
            testMemberAfterJoin.benefitMultiplier,
            BENEFIT_MULTIPLIER,
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
        takasurePool.setKYCStatus(alice);

        uint256 memberIdAfterKyc = takasurePool.memberIdCounter();

        // member values only after KYC verification without joining the pool
        Member memory testMemberAfterKyc = takasurePool.getMemberFromAddress(alice);

        // Check the values
        assertEq(testMemberAfterKyc.memberId, memberIdAfterKyc, "Member ID is not correct");
        assertEq(memberIdAfterJoin, memberIdAfterKyc, "Member ID is not correct");
        assertEq(
            testMemberAfterKyc.benefitMultiplier,
            BENEFIT_MULTIPLIER,
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
