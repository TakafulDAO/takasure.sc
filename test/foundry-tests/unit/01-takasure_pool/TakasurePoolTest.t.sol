// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "../../../../scripts/foundry-deploy/DeployTokenAndPool.s.sol";
import {TakaToken} from "../../../../contracts/token/TakaToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "../../../../contracts/takasure/TakasurePool.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState, KYC} from "../../../../contracts/types/TakasureTypes.sol";
import {IUSDC} from "../../../../contracts/mocks/IUSDCmock.sol";

contract TakasurePoolTest is StdCheats, Test {
    DeployTokenAndPool deployer;
    TakaToken takaToken;
    TakasurePool takasurePool;
    ERC1967Proxy proxy;
    address contributionTokenAddress;
    IUSDC usdc;
    address public backend = makeAddr("backend");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant BENEFIT_MULTIPLIER = 0;
    uint256 public constant YEAR = 365 days;

    event MemberJoined(address indexed member, uint256 indexed contributionAmount, KYC indexed kyc);

    function setUp() public {
        deployer = new DeployTokenAndPool();
        (takaToken, proxy, , contributionTokenAddress, ) = deployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);
        deal(address(usdc), bob, USDC_INITIAL_AMOUNT);

        vm.prank(alice);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);

        vm.prank(bob);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
    }

    /// @dev Test that the joinPool function updates the memberIdCounter
    function testTakasurePool_joinPoolUpdatesCounter() public {
        uint256 memberIdCounterBefore = takasurePool.memberIdCounter();

        vm.prank(alice);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));

        uint256 memberIdCounterAfter = takasurePool.memberIdCounter();

        assertEq(memberIdCounterAfter, memberIdCounterBefore + 1);
    }

    /// @dev Test fund and claim reserves are calculated correctly
    function testTakasurePool_fundAndClaimReserves() public {
        (
            ,
            uint256 initialDynamicReserveRatio,
            ,
            ,
            uint256 initialClaimReserve,
            uint256 initialFundReserve,
            uint8 wakalaFee
        ) = takasurePool.getPoolValues();

        vm.prank(alice);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));

        (, , , , uint256 finalClaimReserve, uint256 finalFundReserve, ) = takasurePool
            .getPoolValues();

        uint256 fee = (CONTRIBUTION_AMOUNT * wakalaFee) / 100; // 25USDC * 20% = 5USDC
        uint256 deposited = CONTRIBUTION_AMOUNT - fee; // 25USDC - 5USDC = 20USDC

        uint256 expectedFinalFundReserve = (deposited * initialDynamicReserveRatio) / 100; // 20USDC * 40% = 8USDC
        uint256 expectedFinalClaimReserve = deposited - expectedFinalFundReserve; // 20USDC - 8USDC = 12USDC

        assertEq(initialClaimReserve, 0);
        assertEq(initialFundReserve, 0);
        assertEq(finalClaimReserve, expectedFinalClaimReserve);
        assertEq(finalClaimReserve, 12e6);
        assertEq(finalFundReserve, expectedFinalFundReserve);
        assertEq(finalFundReserve, 8e6);
    }

    /// @dev Test the membership duration is 5 years if allowCustomDuration is false
    function testTakasurePool_defaultMembershipDuration() public {
        vm.prank(alice);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, YEAR);

        Member memory member = takasurePool.getMemberFromAddress(alice);

        assertEq(member.membershipDuration, 5 * YEAR);
    }

    /// @dev Test the membership custom duration
    function testTakasurePool_customMembershipDuration() public {
        vm.prank(takasurePool.owner());
        takasurePool.setAllowCustomDuration(true);

        vm.prank(alice);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, YEAR);

        Member memory member = takasurePool.getMemberFromAddress(alice);

        assertEq(member.membershipDuration, YEAR);
    }

    modifier aliceJoin() {
        vm.prank(alice);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        _;
    }

    modifier bobJoin() {
        vm.prank(bob);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        _;
    }

    /// @dev Test the member is created
    function testTakasurePool_joinPoolCreateNewMember() public aliceJoin {
        uint256 memberId = takasurePool.memberIdCounter();

        Member memory testMember = takasurePool.getMemberFromId(memberId);

        assertEq(testMember.memberId, memberId);
        assertEq(testMember.benefitMultiplier, BENEFIT_MULTIPLIER);
        assertEq(testMember.netContribution, CONTRIBUTION_AMOUNT);
        assertEq(testMember.wallet, alice);
        assertEq(uint8(testMember.memberState), 1);
    }

    /// @dev More than one can join
    function testTakasurePool_moreThanOneJoin() public aliceJoin bobJoin {
        Member memory aliceMember = takasurePool.getMemberFromAddress(alice);
        Member memory bobMember = takasurePool.getMemberFromAddress(bob);

        (, , , uint256 totalContributions, , , ) = takasurePool.getPoolValues();

        assertEq(aliceMember.wallet, alice);
        assertEq(bobMember.wallet, bob);
        assert(aliceMember.memberId != bobMember.memberId);

        assertEq(totalContributions, 2 * CONTRIBUTION_AMOUNT);
    }
}
