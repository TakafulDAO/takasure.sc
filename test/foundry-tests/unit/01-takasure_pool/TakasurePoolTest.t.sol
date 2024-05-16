// SPDX-License-Identifier: GPL-3.0

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

    /*//////////////////////////////////////////////////////////////
                                  JOIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that the joinPool function updates the memberIdCounter
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

    modifier bobJoin() {
        vm.prank(bob);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        _;
    }

    /// @notice Test the member is created
    function testTakasurePool_joinPoolCreateNewMember() public aliceJoin {
        uint256 memberId = takasurePool.memberIdCounter();

        Member memory testMember = takasurePool.getMemberFromId(memberId);

        assertEq(testMember.memberId, memberId);
        assertEq(testMember.benefitMultiplier, BENEFIT_MULTIPLIER);
        assertEq(testMember.netContribution, CONTRIBUTION_AMOUNT);
        assertEq(testMember.wallet, alice);
        assertEq(uint8(testMember.memberState), 1);
    }

    /// @notice More than one can join
    function testTakasurePool_moreThanOneJoin() public aliceJoin bobJoin {
        Member memory aliceMember = takasurePool.getMemberFromAddress(alice);
        Member memory bobMember = takasurePool.getMemberFromAddress(bob);

        (, , , uint256 totalContributions, , , ) = takasurePool.getPoolValues();

        assertEq(aliceMember.wallet, alice);
        assertEq(bobMember.wallet, bob);
        assert(aliceMember.memberId != bobMember.memberId);

        assertEq(totalContributions, 2 * CONTRIBUTION_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                          MEMBERSHIP DURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Test the membership duration is 5 years if allowCustomDuration is false
    function testTakasurePool_defaultMembershipDuration() public {
        vm.prank(alice);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, YEAR);

        Member memory member = takasurePool.getMemberFromAddress(alice);

        assertEq(member.membershipDuration, 5 * YEAR);
    }

    /// @notice Test the membership custom duration
    function testTakasurePool_customMembershipDuration() public {
        vm.prank(takasurePool.owner());
        takasurePool.setAllowCustomDuration(true);

        vm.prank(alice);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, YEAR);

        Member memory member = takasurePool.getMemberFromAddress(alice);

        assertEq(member.membershipDuration, YEAR);
    }

    /*//////////////////////////////////////////////////////////////
                           CASH & RESERVES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test fund and claim reserves are calculated correctly
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

    /// @notice Cash last 12 months less than a month
    function testTakasurePool_cashLessThanMonth() public {
        address[50] memory lotOfUsers;
        for (uint256 i; i < lotOfUsers.length; i++) {
            lotOfUsers[i] = makeAddr(vm.toString(i));
            deal(address(usdc), lotOfUsers[i], USDC_INITIAL_AMOUNT);
            vm.prank(lotOfUsers[i]);
            usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        }
        // Each day 10 users will join with the contribution amount

        // First day
        for (uint256 i; i < 10; i++) {
            vm.prank(lotOfUsers[i]);
            takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Second day
        for (uint256 i = 10; i < 20; i++) {
            vm.prank(lotOfUsers[i]);
            takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Third day
        for (uint256 i = 20; i < 30; i++) {
            vm.prank(lotOfUsers[i]);
            takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Fourth day
        for (uint256 i = 30; i < 40; i++) {
            vm.prank(lotOfUsers[i]);
            takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Fifth day
        for (uint256 i = 40; i < 50; i++) {
            vm.prank(lotOfUsers[i]);
            takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        uint256 cash = takasurePool.getCalculateCashLast12Months();

        // Each day 25USDC - fee = 20USDC will be deposited
        // 200USDC * 5 days = 1000USDC

        uint256 totalMembers = takasurePool.memberIdCounter();
        (, , , , , , uint8 wakalaFee) = takasurePool.getPoolValues();
        uint256 depositedByEach = CONTRIBUTION_AMOUNT - ((CONTRIBUTION_AMOUNT * wakalaFee) / 100);
        uint256 totalDeposited = totalMembers * depositedByEach;

        assertEq(cash, totalDeposited);
    }

    /// @notice Cash last 12 months more than a month less than a year
    function testTakasurePool_cashMoreThanMonthLessThanYear() public {
        address[100] memory lotOfUsers;
        for (uint256 i; i < lotOfUsers.length; i++) {
            lotOfUsers[i] = makeAddr(vm.toString(i));
            deal(address(usdc), lotOfUsers[i], USDC_INITIAL_AMOUNT);
            vm.prank(lotOfUsers[i]);
            usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        }
        // Test three months two days

        // First month 30 people joins
        // 25USDC - fee = 20USDC
        // 20 * 30 = 600USDC
        for (uint256 i; i < 30; i++) {
            vm.prank(lotOfUsers[i]);
            takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 1);

        // Second 10 people joins
        // 20 * 10 = 200USDC + 600USDC = 800USDC
        for (uint256 i = 30; i < 40; i++) {
            vm.prank(lotOfUsers[i]);
            takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 1);

        // Third month first day 15 people joins
        // 20 * 15 = 300USDC + 800USDC = 1100USDC
        for (uint256 i = 40; i < 55; i++) {
            vm.prank(lotOfUsers[i]);
            takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Third month second day 23 people joins
        // 20 * 23 = 460USDC + 1100USDC = 1560USDC
        for (uint256 i = 55; i < 78; i++) {
            vm.prank(lotOfUsers[i]);
            takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        uint256 cash = takasurePool.getCalculateCashLast12Months();

        uint256 totalMembers = takasurePool.memberIdCounter();
        (, , , , , , uint8 wakalaFee) = takasurePool.getPoolValues();
        uint256 depositedByEach = CONTRIBUTION_AMOUNT - ((CONTRIBUTION_AMOUNT * wakalaFee) / 100);
        uint256 totalDeposited = totalMembers * depositedByEach;

        assertEq(cash, totalDeposited);
    }

    // TODO: Fix this test
    // /// @notice Cash last 12 months more than a  year
    // function testTakasurePool_cashMoreThanYear() public {
    //     address[200] memory lotOfUsers;
    //     for (uint256 i; i < lotOfUsers.length; i++) {
    //         lotOfUsers[i] = makeAddr(vm.toString(i));
    //         deal(address(usdc), lotOfUsers[i], USDC_INITIAL_AMOUNT);
    //         vm.prank(lotOfUsers[i]);
    //         usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
    //     }

    //     // First month 1 people joins daily
    //     for (uint256 i; i < 30; i++) {
    //         vm.prank(lotOfUsers[i]);
    //         takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));

    //         vm.warp(block.timestamp + 1 days);
    //         vm.roll(block.number + 1);
    //     }

    //     // Second month 1 people joins daily
    //     for (uint256 i = 30; i < 60; i++) {
    //         vm.prank(lotOfUsers[i]);
    //         takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));

    //         vm.warp(block.timestamp + 1 days);
    //         vm.roll(block.number + 1);
    //     }

    //     // Third month 1 people joins daily
    //     for (uint256 i = 60; i < 90; i++) {
    //         vm.prank(lotOfUsers[i]);
    //         takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));

    //         vm.warp(block.timestamp + 1 days);
    //         vm.roll(block.number + 1);
    //     }

    //     // Fourth month 10 people joins
    //     for (uint256 i = 90; i < 100; i++) {
    //         vm.prank(lotOfUsers[i]);
    //         takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
    //     }

    //     vm.warp(block.timestamp + 31 days);
    //     vm.roll(block.number + 1);

    //     // Fifth month 10 people joins
    //     for (uint256 i = 100; i < 110; i++) {
    //         vm.prank(lotOfUsers[i]);
    //         takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
    //     }

    //     vm.warp(block.timestamp + 31 days);
    //     vm.roll(block.number + 1);

    //     // Sixth month 10 people joins
    //     for (uint256 i = 110; i < 120; i++) {
    //         vm.prank(lotOfUsers[i]);
    //         takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
    //     }

    //     vm.warp(block.timestamp + 31 days);
    //     vm.roll(block.number + 1);

    //     // Seventh month 10 people joins
    //     for (uint256 i = 120; i < 130; i++) {
    //         vm.prank(lotOfUsers[i]);
    //         takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
    //     }

    //     vm.warp(block.timestamp + 31 days);
    //     vm.roll(block.number + 1);

    //     // Eigth month 10 people joins
    //     for (uint256 i = 130; i < 140; i++) {
    //         vm.prank(lotOfUsers[i]);
    //         takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
    //     }

    //     vm.warp(block.timestamp + 31 days);
    //     vm.roll(block.number + 1);

    //     // Ninth month 10 people joins
    //     for (uint256 i = 140; i < 150; i++) {
    //         vm.prank(lotOfUsers[i]);
    //         takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
    //     }

    //     vm.warp(block.timestamp + 31 days);
    //     vm.roll(block.number + 1);

    //     // Tenth month 10 people joins
    //     for (uint256 i = 150; i < 160; i++) {
    //         vm.prank(lotOfUsers[i]);
    //         takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
    //     }

    //     vm.warp(block.timestamp + 31 days);
    //     vm.roll(block.number + 1);

    //     // Eleventh month 10 people joins
    //     for (uint256 i = 160; i < 170; i++) {
    //         vm.prank(lotOfUsers[i]);
    //         takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
    //     }

    //     vm.warp(block.timestamp + 31 days);
    //     vm.roll(block.number + 1);

    //     // Twelve month 10 people joins
    //     for (uint256 i = 170; i < 180; i++) {
    //         vm.prank(lotOfUsers[i]);
    //         takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
    //     }

    //     vm.warp(block.timestamp + 31 days);
    //     vm.roll(block.number + 1);

    //     // Thirteenth month 10 people joins
    //     for (uint256 i = 180; i < 190; i++) {
    //         vm.prank(lotOfUsers[i]);
    //         takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
    //     }

    //     vm.warp(block.timestamp + 31 days);
    //     vm.roll(block.number + 1);

    //     // Fourteenth month 10 people joins
    //     for (uint256 i = 160; i < 170; i++) {
    //         vm.prank(lotOfUsers[i]);
    //         takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
    //     }

    //     vm.warp(block.timestamp + 31 days);
    //     vm.roll(block.number + 1);

    //     // Last 2 days 2 people joins
    //     for (uint256 i = 170; i < 172; i++) {
    //         vm.prank(lotOfUsers[i]);
    //         takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));

    //         vm.warp(block.timestamp + 1 days);
    //         vm.roll(block.number + 1);
    //     }

    //     // Month 1 = 600USDC -> Should not be included
    //     // Month 2 = 600USDC -> Should not be included
    //     // Month 3 = 600USDC -> count 28 days -> 20USDC * 28 = 560USDC
    //     // Month 4 = 200USDC -> Total = 760USDC
    //     // Month 5 = 200USDC -> Total = 960USDC
    //     // Month 6 = 200USDC -> Total = 1160USDC
    //     // Month 7 = 200USDC -> Total = 1360USDC
    //     // Month 8 = 200USDC -> Total = 1560USDC
    //     // Month 9 = 200USDC -> Total = 1760USDC
    //     // Month 10 = 200USDC -> Total = 1960USDC
    //     // Month 11 = 200USDC -> Total = 2160USDC
    //     // Month 12 = 200USDC -> Total = 2360USDC
    //     // Month 13 = 200USDC -> Total = 2560USDC
    //     // Month 14 = 200USDC -> Total = 2760USDC
    //     // Month 15 -> first day = 20USDC -> Total = 2780USDC
    //     // Month 15 -> second day = 20USDC -> Total = 2800USDC

    //     uint256 cash = takasurePool.getCalculateCashLast12Months();

    //     assertEq(cash, 2800e6);
    // }
}
