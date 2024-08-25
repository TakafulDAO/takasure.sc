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
    address public eve = makeAddr("eve");

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
        tokensTo(eve)
    {
        // Alice joins in day 1
        uint256 day1 = block.timestamp;
        _join(alice, 1);

        uint256 surplusDay1 = takasurePool.getSurplus();
        Member memory ALICE = takasurePool.getMemberFromAddress(alice);

        assertEq(surplusDay1, 117e5);
        assertEq(surplusDay1, ALICE.lastEcr);
        assertEq(ALICE.lastUcr, 0);
        assertEq(ALICE.memberSurplus, 0);
        assertEq(ALICE.lastEcrTime, day1);

        // Bob joins in day 1
        _join(bob, 3);

        surplusDay1 = takasurePool.getSurplus();
        ALICE = takasurePool.getMemberFromAddress(alice);
        Member memory BOB = takasurePool.getMemberFromAddress(bob);

        assertEq(surplusDay1, 351e5);
        assert(surplusDay1 > ALICE.lastEcr);
        assert(surplusDay1 > ALICE.lastUcr);
        assertEq(ALICE.memberSurplus, 0);
        assertEq(ALICE.lastEcrTime, day1);
        assertEq(surplusDay1, BOB.lastEcr);
        assertEq(BOB.lastUcr, 0);
        assertEq(BOB.memberSurplus, 0);
        assertEq(BOB.lastEcrTime, day1);

        // 1 day passes
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Charlie joins in day 2
        _join(charlie, 10);

        uint256 surplusDay2 = takasurePool.getSurplus();
        console2.log("surplusDay2", surplusDay2);

        assert(surplusDay2 > surplusDay1);

        // 1 day passes
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // David joins in day 3
        _join(david, 5);

        uint256 surplusDay3 = takasurePool.getSurplus();
        console2.log("surplusDay3", surplusDay3);

        assert(surplusDay3 < surplusDay2);

        // 1 day passes
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Eve joins in day 4
        _join(eve, 2);

        uint256 surplusDay4 = takasurePool.getSurplus();
        console2.log("surplusDay4", surplusDay4);

        assert(surplusDay4 < surplusDay3);
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
