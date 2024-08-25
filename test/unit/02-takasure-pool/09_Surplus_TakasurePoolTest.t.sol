// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {DeployConsumerMocks} from "test/utils/DeployConsumerMocks.s.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract Refund_TakasurePoolTest is StdCheats, Test, SimulateDonResponse {
    TestDeployTakasure deployer;
    DeployConsumerMocks mockDeployer;
    TakasurePool takasurePool;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConnsumerMock;
    address proxy;
    address contributionTokenAddress;
    address admin;
    IUSDC usdc;
    uint256 public constant USDC_INITIAL_AMOUNT = 500e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant YEAR = 365 days;

    // Users
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public david = makeAddr("david");
    address public erin = makeAddr("erin");
    address public frank = makeAddr("frank");

    function setUp() public {
        deployer = new TestDeployTakasure();
        (, proxy, contributionTokenAddress, helperConfig) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;

        mockDeployer = new DeployConsumerMocks();
        bmConnsumerMock = mockDeployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        vm.prank(admin);
        takasurePool.setNewBenefitMultiplierConsumer(address(bmConnsumerMock));

        vm.prank(msg.sender);
        bmConnsumerMock.setNewRequester(address(takasurePool));
    }

    modifier tokensTo(address user) {
        deal(address(usdc), user, USDC_INITIAL_AMOUNT);
        vm.startPrank(user);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        vm.stopPrank;
        _;
    }

    function testTakasurePool_surplus()
        public
        tokensTo(alice)
        tokensTo(bob)
        tokensTo(charlie)
        tokensTo(david)
        tokensTo(erin)
        tokensTo(frank)
    {
        // Alice joins in day 1
        _join(alice, 1);

        (uint256 ECRes, int256 UCRes, uint256 surplus) = takasurePool.getSurplus();
        Member memory ALICE = takasurePool.getMemberFromAddress(alice);

        assertEq(ALICE.lastEcr, 0);
        assertEq(ALICE.lastUcr, 0);
        assertEq(ECRes, 0);
        assertEq(UCRes, 0);
        assertEq(surplus, 0);

        // Bob joins in day 1
        _join(bob, 3);

        (ECRes, UCRes, surplus) = takasurePool.getSurplus();
        ALICE = takasurePool.getMemberFromAddress(alice);
        Member memory BOB = takasurePool.getMemberFromAddress(bob);

        assertEq(ALICE.lastEcr, 117e5);
        assertEq(ALICE.lastUcr, 0);
        assertEq(BOB.lastEcr, 0);
        assertEq(BOB.lastUcr, 0);
        assertEq(ECRes, 117e5);
        assertEq(UCRes, 0);
        assertEq(surplus, 117e5);

        // 1 day passes
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Charlie joins in day 2
        _join(charlie, 10);

        (ECRes, UCRes, surplus) = takasurePool.getSurplus();
        ALICE = takasurePool.getMemberFromAddress(alice);
        BOB = takasurePool.getMemberFromAddress(bob);
        Member memory CHARLIE = takasurePool.getMemberFromAddress(charlie);

        assertEq(ALICE.lastEcr, 11723400);
        assertEq(ALICE.lastUcr, -23400);
        assertEq(BOB.lastEcr, 34994700);
        assertEq(BOB.lastUcr, 105300);
        assertEq(CHARLIE.lastEcr, 0);
        assertEq(CHARLIE.lastUcr, 0);
        assertEq(ECRes, 58418100);
        assertEq(UCRes, 81900);
        assertEq(surplus, 58418100);

        // 1 day passes
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // David joins in day 3
        _join(david, 5);

        (ECRes, UCRes, surplus) = takasurePool.getSurplus();
        ALICE = takasurePool.getMemberFromAddress(alice);
        BOB = takasurePool.getMemberFromAddress(bob);
        CHARLIE = takasurePool.getMemberFromAddress(charlie);
        Member memory DAVID = takasurePool.getMemberFromAddress(david);

        assertEq(ALICE.lastEcr, 11746800);
        assertEq(ALICE.lastUcr, -46800);
        assertEq(BOB.lastEcr, 35064900);
        assertEq(BOB.lastUcr, 35100);
        assertEq(CHARLIE.lastEcr, 116649000);
        assertEq(CHARLIE.lastUcr, 351000);
        assertEq(DAVID.lastEcr, 0);
        assertEq(DAVID.lastUcr, 0);
        assertEq(ECRes, 221878800);
        assertEq(UCRes, 339300);
        assertEq(surplus, 221878800);

        // 1 day passes
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Erin joins in day 4
        _join(erin, 2);

        (ECRes, UCRes, surplus) = takasurePool.getSurplus();
        ALICE = takasurePool.getMemberFromAddress(alice);
        BOB = takasurePool.getMemberFromAddress(bob);
        CHARLIE = takasurePool.getMemberFromAddress(charlie);
        DAVID = takasurePool.getMemberFromAddress(david);
        Member memory ERIN = takasurePool.getMemberFromAddress(erin);

        assertEq(ALICE.lastEcr, 11770200);
        assertEq(ALICE.lastUcr, -70200);
        assertEq(BOB.lastEcr, 35135100);
        assertEq(BOB.lastUcr, -35100);
        assertEq(CHARLIE.lastEcr, 116883000);
        assertEq(CHARLIE.lastUcr, 117000);
        assertEq(DAVID.lastEcr, 58324500);
        assertEq(DAVID.lastUcr, 175500);
        assertEq(ERIN.lastEcr, 0);
        assertEq(ERIN.lastUcr, 0);
        assertEq(ECRes, 443991600);
        assertEq(UCRes, 187200);
        assertEq(surplus, 443991600);

        // 1 day passes
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Frank joins in day 5
        _join(frank, 7);

        (ECRes, UCRes, surplus) = takasurePool.getSurplus();
        ALICE = takasurePool.getMemberFromAddress(alice);
        BOB = takasurePool.getMemberFromAddress(bob);
        CHARLIE = takasurePool.getMemberFromAddress(charlie);
        DAVID = takasurePool.getMemberFromAddress(david);
        ERIN = takasurePool.getMemberFromAddress(erin);
        Member memory FRANK = takasurePool.getMemberFromAddress(frank);

        assertEq(ALICE.lastEcr, 11793600);
        assertEq(ALICE.lastUcr, -93600);
        assertEq(BOB.lastEcr, 35205300);
        assertEq(BOB.lastUcr, -105300);
        assertEq(CHARLIE.lastEcr, 117117000);
        assertEq(CHARLIE.lastUcr, -117000);
        assertEq(DAVID.lastEcr, 58441500);
        assertEq(DAVID.lastUcr, 58500);
        assertEq(ERIN.lastEcr, 23329800);
        assertEq(ERIN.lastUcr, 70200);
        assertEq(FRANK.lastEcr, 0);
        assertEq(FRANK.lastUcr, 0);
        assertEq(ECRes, 689878800);
        assertEq(UCRes, -187200);
        assertEq(surplus, 689691600);
    }

    function _join(address user, uint256 timesContributionAmount) internal {
        vm.startPrank(user);
        takasurePool.joinPool(timesContributionAmount * CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        // We simulate a request before the KYC
        _successResponse(address(bmConnsumerMock));

        vm.startPrank(admin);
        takasurePool.setKYCStatus(user);
        vm.stopPrank();
    }
}
