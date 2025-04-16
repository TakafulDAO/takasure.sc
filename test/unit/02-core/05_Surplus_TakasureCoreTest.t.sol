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
        assertEq(ALICE.lastEcr, 10_950_000);
        assertEq(ALICE.lastUcr, 0);
        assertEq(BOB.lastEcr, 0);
        assertEq(BOB.lastUcr, 0);
        assertEq(ECRes, 10_950_000);
        assertEq(UCRes, 0);
        assertEq(surplus, 10_950_000);
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
        assertEq(ALICE.lastEcr, 10_917_150);
        assertEq(ALICE.lastUcr, 32_850);
        assertEq(BOB.lastEcr, 28_384_590);
        assertEq(BOB.lastUcr, 85_410);
        assertEq(CHARLIE.lastEcr, 0);
        assertEq(CHARLIE.lastUcr, 0);
        assertEq(ECRes, 39_301_740);
        assertEq(UCRes, 118_260);
        assertEq(surplus, 39_301_740);
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
        assertEq(ALICE.lastEcr, 10_884_300);
        assertEq(ALICE.lastUcr, 65_700);
        assertEq(BOB.lastEcr, 28_299_180);
        assertEq(BOB.lastUcr, 170_820);
        assertEq(CHARLIE.lastEcr, 103_712_925);
        assertEq(CHARLIE.lastUcr, 312_075);
        assertEq(DAVID.lastEcr, 0);
        assertEq(DAVID.lastUcr, 0);
        assertEq(ECRes, 142_896_405);
        assertEq(UCRes, 548_595);
        assertEq(surplus, 142_896_405);
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
        assertEq(ALICE.lastEcr, 10_851_450);
        assertEq(ALICE.lastUcr, 98_550);
        assertEq(BOB.lastEcr, 28_213_770);
        assertEq(BOB.lastUcr, 256_230);
        assertEq(CHARLIE.lastEcr, 103_400_850);
        assertEq(CHARLIE.lastUcr, 624_150);
        assertEq(DAVID.lastEcr, 50_946_700);
        assertEq(DAVID.lastUcr, 153_300);
        assertEq(ERIN.lastEcr, 0);
        assertEq(ERIN.lastUcr, 0);
        assertEq(ECRes, 193_412_770);
        assertEq(UCRes, 1_132_230);
        assertEq(surplus, 193_412_770);
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
        assertEq(ALICE.lastEcr, 10_829_550);
        assertEq(ALICE.lastUcr, 120_450);
        assertEq(BOB.lastEcr, 28_156_830);
        assertEq(BOB.lastUcr, 313_170);
        assertEq(CHARLIE.lastEcr, 103_088_775);
        assertEq(CHARLIE.lastUcr, 936_225);
        assertEq(DAVID.lastEcr, 50_793_400);
        assertEq(DAVID.lastUcr, 306_600);
        assertEq(ERIN.lastEcr, 20_378_680);
        assertEq(ERIN.lastUcr, 61_320);
        assertEq(FRANK.lastEcr, 0);
        assertEq(FRANK.lastUcr, 0);
        assertEq(ECRes, 213_247_235);
        assertEq(UCRes, 1_737_765);
        assertEq(surplus, 213_247_235);
    }

    function _join(address user, uint256 timesContributionAmount) internal {
        vm.startPrank(user);
        userRouter.joinPool(parent, timesContributionAmount * CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.startPrank(admin);
        entryModule.approveKYC(user);
        vm.stopPrank();
    }
}
