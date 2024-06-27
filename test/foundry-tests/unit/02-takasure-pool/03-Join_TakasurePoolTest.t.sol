// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "../../../../scripts/foundry-deploy/DeployTokenAndPool.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "../../../../contracts/takasure/TakasurePool.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState} from "../../../../contracts/types/TakasureTypes.sol";
import {IUSDC} from "../../../../contracts/mocks/IUSDCmock.sol";

contract Join_TakasurePoolTest is StdCheats, Test {
    DeployTokenAndPool deployer;
    TakasurePool takasurePool;
    ERC1967Proxy proxy;
    address contributionTokenAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
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
        deal(address(usdc), bob, USDC_INITIAL_AMOUNT);

        vm.prank(alice);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);

        vm.prank(bob);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                                  JOIN
    //////////////////////////////////////////////////////////////*/

    /// @dev Test the contribution amount's last four digits are zero
    function testTakasurePool_contributionAmountDecimals() public {
        uint256 contributionAmount = 227123456; // 227.123456 USDC

        deal(address(usdc), alice, contributionAmount);

        vm.startPrank(alice);

        usdc.approve(address(takasurePool), contributionAmount);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, contributionAmount, (5 * YEAR));

        vm.stopPrank();

        (, , , uint256 totalContributions, , , , , , , , ) = takasurePool.getReserveValues();

        uint256 memberId = takasurePool.memberIdCounter();
        Member memory member = takasurePool.getMemberFromId(memberId);

        assertEq(member.contribution, 227120000); // 227.120000 USDC
        assertEq(totalContributions, member.contribution);
    }

    /*//////////////////////////////////////////////////////////////
                      JOIN POOL::CREATE NEW MEMBER
    //////////////////////////////////////////////////////////////*/

    /// @dev Test that the joinPool function updates the memberIdCounter
    function testTakasurePool_joinPoolUpdatesCounter() public {
        uint256 memberIdCounterBefore = takasurePool.memberIdCounter();

        vm.prank(alice);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));

        uint256 memberIdCounterAfter = takasurePool.memberIdCounter();

        assertEq(memberIdCounterAfter, memberIdCounterBefore + 1);
    }

    modifier aliceJoin() {
        vm.prank(alice);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        _;
    }

    /// @dev Test the membership duration is 5 years if allowCustomDuration is false
    function testTakasurePool_defaultMembershipDuration() public aliceJoin {
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

    /// @dev Test the member is created
    function testTakasurePool_newMember() public aliceJoin {
        uint256 memberId = takasurePool.memberIdCounter();

        // Check the member is created and added correctly to mappings
        // idToMember[memberId]
        Member memory testMember = takasurePool.getMemberFromId(memberId);
        Member memory testMember2 = takasurePool.getMemberFromAddress(alice);

        assertEq(testMember.memberId, memberId);
        assertEq(testMember.benefitMultiplier, BENEFIT_MULTIPLIER);
        assertEq(testMember.contribution, CONTRIBUTION_AMOUNT);
        assertEq(testMember.wallet, alice);
        assertEq(uint8(testMember.memberState), 1);

        // Both members should be the same
        assertEq(testMember.memberId, testMember2.memberId);
        assertEq(testMember.wallet, testMember2.wallet);
    }

    modifier bobJoin() {
        vm.prank(bob);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        _;
    }

    /// @dev More than one can join
    function testTakasurePool_moreThanOneJoin() public aliceJoin bobJoin {
        Member memory aliceMember = takasurePool.getMemberFromAddress(alice);
        Member memory bobMember = takasurePool.getMemberFromAddress(bob);

        (, , , uint256 totalContributions, , , , , , , , ) = takasurePool.getReserveValues();

        assertEq(aliceMember.wallet, alice);
        assertEq(bobMember.wallet, bob);
        assert(aliceMember.memberId != bobMember.memberId);

        assertEq(totalContributions, 2 * CONTRIBUTION_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                    JOIN POOL::UPDATE BOTH PRO FORMAS
    //////////////////////////////////////////////////////////////*/
    /// @dev Pro formas updated when a member joins
    function testTakasurePool_proFormasUpdatedOnMemberJoined() public aliceJoin {
        (
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 initialProFormaFundReserve,
            uint256 initialProFormaClaimReserve,
            ,
            ,
            ,

        ) = takasurePool.getReserveValues();

        vm.prank(bob);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));

        (
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 finalProFormaFundReserve,
            uint256 finalProFormaClaimReserve,
            ,
            ,
            ,

        ) = takasurePool.getReserveValues();

        assert(finalProFormaFundReserve > initialProFormaFundReserve);
        assert(finalProFormaClaimReserve > initialProFormaClaimReserve);
    }

    /*//////////////////////////////////////////////////////////////
                         JOIN POOL::UPDATE DRR
    //////////////////////////////////////////////////////////////*/
    /// @dev New DRR is calculated when a member joins
    function testTakasurePool_drrCalculatedOnMemberJoined() public {
        (uint256 initialDRR, uint256 currentDRR, , , , , , , , , , ) = takasurePool
            .getReserveValues();

        vm.prank(alice);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));

        (, uint256 aliceDRR, , , , , , , , , , ) = takasurePool.getReserveValues();

        vm.prank(bob);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));

        (, uint256 bobDRR, , , , , , , , , , ) = takasurePool.getReserveValues();

        uint256 expectedInitialDRR = 40;
        uint256 expectedAliceDRR = 50;
        uint256 expectedBobDRR = 61;

        assertEq(initialDRR, expectedInitialDRR);
        assertEq(currentDRR, initialDRR);
        assertEq(aliceDRR, expectedAliceDRR);
        assertEq(bobDRR, expectedBobDRR);
    }

    /*//////////////////////////////////////////////////////////////
                         JOIN POOL::UPDATE BMA
    //////////////////////////////////////////////////////////////*/
    /// @dev New BMA is calculated when a member joins
    function testTakasurePool_bmaCalculatedOnMemberJoined() public {
        (, , uint256 initialBMA, , , , , , , , , ) = takasurePool.getReserveValues();

        vm.prank(alice);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));

        (, , uint256 aliceBMA, , , , , , , , , ) = takasurePool.getReserveValues();

        vm.prank(bob);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));

        (, , uint256 bobBMA, , , , , , , , , ) = takasurePool.getReserveValues();

        uint256 expectedInitialBMA = 100;
        uint256 expectedAliceBMA = 91;
        uint256 expectedBobBMA = 88;

        assertEq(initialBMA, expectedInitialBMA);
        assertEq(aliceBMA, expectedAliceBMA);
        assertEq(bobBMA, expectedBobBMA);
    }
}
