// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";
import {UserRouter} from "contracts/router/UserRouter.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState, Reserve} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract Surplus_TakasureCoreTest is StdCheats, Test, SimulateDonResponse {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    EntryModule entryModule;
    MemberModule memberModule;
    UserRouter userRouter;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address admin;
    address kycService;
    address takadao;
    address entryModuleAddress;
    address memberModuleAddress;
    address userRouterAddress;
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
    address public parent = makeAddr("parent");

    function setUp() public {
        deployer = new TestDeployProtocol();
        (
            ,
            bmConsumerMock,
            takasureReserveProxy,
            ,
            entryModuleAddress,
            memberModuleAddress,
            ,
            userRouterAddress,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        entryModule = EntryModule(entryModuleAddress);
        memberModule = MemberModule(memberModuleAddress);
        userRouter = UserRouter(userRouterAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        kycService = config.kycProvider;
        takadao = config.takadaoOperator;

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(entryModuleAddress));

        vm.prank(takadao);
        entryModule.updateBmAddress();
    }

    modifier tokensTo(address user) {
        deal(address(usdc), user, USDC_INITIAL_AMOUNT);
        vm.startPrank(user);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testTakasureCore_surplus()
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
        Reserve memory reserve = takasureReserve.getReserveValues();
        uint256 ECRes = reserve.ECRes;
        uint256 UCRes = reserve.UCRes;
        uint256 surplus = reserve.surplus;
        Member memory ALICE = takasureReserve.getMemberFromAddress(alice);
        assertEq(ALICE.lastEcr, 0);
        assertEq(ALICE.lastUcr, 0);
        assertEq(ECRes, 0);
        assertEq(UCRes, 0);
        assertEq(surplus, 0);
        // Bob joins in day 1
        _join(bob, 3);
        reserve = takasureReserve.getReserveValues();
        ECRes = reserve.ECRes;
        UCRes = reserve.UCRes;
        surplus = reserve.surplus;
        ALICE = takasureReserve.getMemberFromAddress(alice);
        Member memory BOB = takasureReserve.getMemberFromAddress(bob);
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
        reserve = takasureReserve.getReserveValues();
        ECRes = reserve.ECRes;
        UCRes = reserve.UCRes;
        surplus = reserve.surplus;
        ALICE = takasureReserve.getMemberFromAddress(alice);
        BOB = takasureReserve.getMemberFromAddress(bob);
        Member memory CHARLIE = takasureReserve.getMemberFromAddress(charlie);
        assertEq(ALICE.lastEcr, 11_664_900);
        assertEq(ALICE.lastUcr, 35_100);
        assertEq(BOB.lastEcr, 30_328_740);
        assertEq(BOB.lastUcr, 91_260);
        assertEq(CHARLIE.lastEcr, 0);
        assertEq(CHARLIE.lastUcr, 0);
        assertEq(ECRes, 41_993_640);
        assertEq(UCRes, 126_360);
        assertEq(surplus, 41_993_640);
        // 1 day passes
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // David joins in day 3
        _join(david, 5);
        reserve = takasureReserve.getReserveValues();
        ECRes = reserve.ECRes;
        UCRes = reserve.UCRes;
        surplus = reserve.surplus;
        ALICE = takasureReserve.getMemberFromAddress(alice);
        BOB = takasureReserve.getMemberFromAddress(bob);
        CHARLIE = takasureReserve.getMemberFromAddress(charlie);
        Member memory DAVID = takasureReserve.getMemberFromAddress(david);
        assertEq(ALICE.lastEcr, 11_629_800);
        assertEq(ALICE.lastUcr, 70_200);
        assertEq(BOB.lastEcr, 30_237_480);
        assertEq(BOB.lastUcr, 182_520);
        assertEq(CHARLIE.lastEcr, 110_816_550);
        assertEq(CHARLIE.lastUcr, 333_450);
        assertEq(DAVID.lastEcr, 0);
        assertEq(DAVID.lastUcr, 0);
        assertEq(ECRes, 152_683_830);
        assertEq(UCRes, 586_170);
        assertEq(surplus, 152_683_830);
        // 1 day passes
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // Erin joins in day 4
        _join(erin, 2);
        reserve = takasureReserve.getReserveValues();
        ECRes = reserve.ECRes;
        UCRes = reserve.UCRes;
        surplus = reserve.surplus;
        ALICE = takasureReserve.getMemberFromAddress(alice);
        BOB = takasureReserve.getMemberFromAddress(bob);
        CHARLIE = takasureReserve.getMemberFromAddress(charlie);
        DAVID = takasureReserve.getMemberFromAddress(david);
        Member memory ERIN = takasureReserve.getMemberFromAddress(erin);
        assertEq(ALICE.lastEcr, 11_594_700);
        assertEq(ALICE.lastUcr, 105_300);
        assertEq(BOB.lastEcr, 30_146_220);
        assertEq(BOB.lastUcr, 273_780);
        assertEq(CHARLIE.lastEcr, 110_483_100);
        assertEq(CHARLIE.lastUcr, 666_900);
        assertEq(DAVID.lastEcr, 54_436_200);
        assertEq(DAVID.lastUcr, 163_800);
        assertEq(ERIN.lastEcr, 0);
        assertEq(ERIN.lastUcr, 0);
        assertEq(ECRes, 206_660_220);
        assertEq(UCRes, 1_209_780);
        assertEq(surplus, 206_660_220);
        // 1 day passes
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);
        // Frank joins in day 5
        _join(frank, 7);
        reserve = takasureReserve.getReserveValues();
        ECRes = reserve.ECRes;
        UCRes = reserve.UCRes;
        surplus = reserve.surplus;
        ALICE = takasureReserve.getMemberFromAddress(alice);
        BOB = takasureReserve.getMemberFromAddress(bob);
        CHARLIE = takasureReserve.getMemberFromAddress(charlie);
        DAVID = takasureReserve.getMemberFromAddress(david);
        ERIN = takasureReserve.getMemberFromAddress(erin);
        Member memory FRANK = takasureReserve.getMemberFromAddress(frank);
        assertEq(ALICE.lastEcr, 11_571_300);
        assertEq(ALICE.lastUcr, 128_700);
        assertEq(BOB.lastEcr, 30_085_380);
        assertEq(BOB.lastUcr, 334_620);
        assertEq(CHARLIE.lastEcr, 110_149_650);
        assertEq(CHARLIE.lastUcr, 1_000_350);
        assertEq(DAVID.lastEcr, 54_272_400);
        assertEq(DAVID.lastUcr, 327_600);
        assertEq(ERIN.lastEcr, 21_774_480);
        assertEq(ERIN.lastUcr, 65_520);
        assertEq(FRANK.lastEcr, 0);
        assertEq(FRANK.lastUcr, 0);
        assertEq(ECRes, 227_853_210);
        assertEq(UCRes, 1_856_790);
        assertEq(surplus, 227_853_210);
    }

    function _join(address user, uint256 timesContributionAmount) internal {
        vm.startPrank(user);
        userRouter.joinPool(parent, timesContributionAmount * CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.startPrank(admin);
        entryModule.setKYCStatus(user);
        vm.stopPrank();
    }
}
