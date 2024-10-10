// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasureReserve} from "test/utils/TestDeployTakasureReserve.s.sol";
import {DeployConsumerMocks} from "test/utils/DeployConsumerMocks.s.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/takasure/core/TakasureReserve.sol";
import {JoinModule} from "contracts/takasure/modules/JoinModule.sol";
import {MembersModule} from "contracts/takasure/modules/MembersModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState, Reserve} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract Surplus_TakasureProtocolTest is StdCheats, Test, SimulateDonResponse {
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
        deployer = new TestDeployTakasureReserve();
        (
            takasureReserveProxy,
            joinModuleAddress,
            membersModuleAddress,
            ,
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

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(msg.sender);
        bmConsumerMock.setNewRequester(address(joinModuleAddress));

        vm.prank(takadao);
        joinModule.updateBmAddress();
    }

    // Todo: Implement surplus functions to make it work
    // modifier tokensTo(address user) {
    //     deal(address(usdc), user, USDC_INITIAL_AMOUNT);
    //     vm.startPrank(user);
    //     usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);
    //     vm.stopPrank;
    //     _;
    // }

    // function testTakasurePool_surplus()
    //     public
    //     tokensTo(alice)
    //     tokensTo(bob)
    //     tokensTo(charlie)
    //     tokensTo(david)
    //     tokensTo(erin)
    //     tokensTo(frank)
    // {
    //     // Alice joins in day 1
    //     _join(alice, 1);

    //     Reserve memory reserve = takasureReserve.getReserveValues();
    //     uint256 ECRes = reserve.ECRes;
    //     uint256 UCRes = reserve.UCRes;
    //     uint256 surplus = reserve.surplus;
    //     Member memory ALICE = takasureReserve.getMemberFromAddress(alice);

    //     assertEq(ALICE.lastEcr, 0);
    //     assertEq(ALICE.lastUcr, 0);
    //     assertEq(ECRes, 0);
    //     assertEq(UCRes, 0);
    //     assertEq(surplus, 0);

    //     // Bob joins in day 1
    //     _join(bob, 3);

    //     reserve = takasureReserve.getReserveValues();
    //     ECRes = reserve.ECRes;
    //     UCRes = reserve.UCRes;
    //     surplus = reserve.surplus;
    //     ALICE = takasureReserve.getMemberFromAddress(alice);
    //     Member memory BOB = takasureReserve.getMemberFromAddress(bob);

    //     assertEq(ALICE.lastEcr, 117e5);
    //     assertEq(ALICE.lastUcr, 0);
    //     assertEq(BOB.lastEcr, 0);
    //     assertEq(BOB.lastUcr, 0);
    //     assertEq(ECRes, 117e5);
    //     assertEq(UCRes, 0);
    //     assertEq(surplus, 117e5);

    //     // 1 day passes
    //     vm.warp(block.timestamp + 1 days);
    //     vm.roll(block.number + 1);

    //     // Charlie joins in day 2
    //     _join(charlie, 10);

    //     reserve = takasureReserve.getReserveValues();
    //     ECRes = reserve.ECRes;
    //     UCRes = reserve.UCRes;
    //     surplus = reserve.surplus;
    //     ALICE = takasureReserve.getMemberFromAddress(alice);
    //     BOB = takasureReserve.getMemberFromAddress(bob);
    //     Member memory CHARLIE = takasureReserve.getMemberFromAddress(charlie);

    //     assertEq(ALICE.lastEcr, 11_664_900);
    //     assertEq(ALICE.lastUcr, 35_100);
    //     assertEq(BOB.lastEcr, 30_328_740);
    //     assertEq(BOB.lastUcr, 91_260);
    //     assertEq(CHARLIE.lastEcr, 0);
    //     assertEq(CHARLIE.lastUcr, 0);
    //     assertEq(ECRes, 41_993_640);
    //     assertEq(UCRes, 126_360);
    //     assertEq(surplus, 41_993_640);

    //     // 1 day passes
    //     vm.warp(block.timestamp + 1 days);
    //     vm.roll(block.number + 1);

    //     // David joins in day 3
    //     _join(david, 5);

    //     reserve = takasureReserve.getReserveValues();
    //     ECRes = reserve.ECRes;
    //     UCRes = reserve.UCRes;
    //     surplus = reserve.surplus;
    //     ALICE = takasureReserve.getMemberFromAddress(alice);
    //     BOB = takasureReserve.getMemberFromAddress(bob);
    //     CHARLIE = takasureReserve.getMemberFromAddress(charlie);
    //     Member memory DAVID = takasureReserve.getMemberFromAddress(david);

    //     assertEq(ALICE.lastEcr, 11_629_800);
    //     assertEq(ALICE.lastUcr, 70_200);
    //     assertEq(BOB.lastEcr, 30_237_480);
    //     assertEq(BOB.lastUcr, 182_520);
    //     assertEq(CHARLIE.lastEcr, 110_816_550);
    //     assertEq(CHARLIE.lastUcr, 333_450);
    //     assertEq(DAVID.lastEcr, 0);
    //     assertEq(DAVID.lastUcr, 0);
    //     assertEq(ECRes, 152_683_830);
    //     assertEq(UCRes, 586_170);
    //     assertEq(surplus, 152_683_830);

    //     // 1 day passes
    //     vm.warp(block.timestamp + 1 days);
    //     vm.roll(block.number + 1);

    //     // Erin joins in day 4
    //     _join(erin, 2);

    //     reserve = takasureReserve.getReserveValues();
    //     ECRes = reserve.ECRes;
    //     UCRes = reserve.UCRes;
    //     surplus = reserve.surplus;
    //     ALICE = takasureReserve.getMemberFromAddress(alice);
    //     BOB = takasureReserve.getMemberFromAddress(bob);
    //     CHARLIE = takasureReserve.getMemberFromAddress(charlie);
    //     DAVID = takasureReserve.getMemberFromAddress(david);
    //     Member memory ERIN = takasureReserve.getMemberFromAddress(erin);

    //     assertEq(ALICE.lastEcr, 11_594_700);
    //     assertEq(ALICE.lastUcr, 105_300);
    //     assertEq(BOB.lastEcr, 30_146_220);
    //     assertEq(BOB.lastUcr, 273_780);
    //     assertEq(CHARLIE.lastEcr, 110_483_100);
    //     assertEq(CHARLIE.lastUcr, 666_900);
    //     assertEq(DAVID.lastEcr, 54_436_200);
    //     assertEq(DAVID.lastUcr, 163_800);
    //     assertEq(ERIN.lastEcr, 0);
    //     assertEq(ERIN.lastUcr, 0);
    //     assertEq(ECRes, 206_660_220);
    //     assertEq(UCRes, 1_209_780);
    //     assertEq(surplus, 206_660_220);

    //     // 1 day passes
    //     vm.warp(block.timestamp + 1 days);
    //     vm.roll(block.number + 1);

    //     // Frank joins in day 5
    //     _join(frank, 7);

    //     reserve = takasureReserve.getReserveValues();
    //     ECRes = reserve.ECRes;
    //     UCRes = reserve.UCRes;
    //     surplus = reserve.surplus;
    //     ALICE = takasureReserve.getMemberFromAddress(alice);
    //     BOB = takasureReserve.getMemberFromAddress(bob);
    //     CHARLIE = takasureReserve.getMemberFromAddress(charlie);
    //     DAVID = takasureReserve.getMemberFromAddress(david);
    //     ERIN = takasureReserve.getMemberFromAddress(erin);
    //     Member memory FRANK = takasureReserve.getMemberFromAddress(frank);

    //     assertEq(ALICE.lastEcr, 11_571_300);
    //     assertEq(ALICE.lastUcr, 128_700);
    //     assertEq(BOB.lastEcr, 30_085_380);
    //     assertEq(BOB.lastUcr, 334_620);
    //     assertEq(CHARLIE.lastEcr, 110_149_650);
    //     assertEq(CHARLIE.lastUcr, 1_000_350);
    //     assertEq(DAVID.lastEcr, 54_272_400);
    //     assertEq(DAVID.lastUcr, 327_600);
    //     assertEq(ERIN.lastEcr, 21_774_480);
    //     assertEq(ERIN.lastUcr, 65_520);
    //     assertEq(FRANK.lastEcr, 0);
    //     assertEq(FRANK.lastUcr, 0);
    //     assertEq(ECRes, 227_853_210);
    //     assertEq(UCRes, 1_856_790);
    //     assertEq(surplus, 227_853_210);
    // }

    // function _join(address user, uint256 timesContributionAmount) internal {
    //     vm.startPrank(user);
    //     joinModule.joinPool(timesContributionAmount * CONTRIBUTION_AMOUNT, 5 * YEAR);
    //     vm.stopPrank();

    //     // We simulate a request before the KYC
    //     _successResponse(address(bmConsumerMock));

    //     vm.startPrank(admin);
    //     joinModule.setKYCStatus(user);
    //     vm.stopPrank();
    // }
}
