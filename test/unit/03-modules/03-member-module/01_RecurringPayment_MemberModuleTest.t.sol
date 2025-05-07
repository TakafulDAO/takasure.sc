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
import {Member, MemberState} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract RecurringPayment_MemberModuleTest is StdCheats, Test, SimulateDonResponse {
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
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public parent = makeAddr("parent");
    uint256 public constant USDC_INITIAL_AMOUNT = 150e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant YEAR = 365 days;

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

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);
        deal(address(usdc), bob, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(memberModule), USDC_INITIAL_AMOUNT);

        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(memberModule), USDC_INITIAL_AMOUNT);

        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.startPrank(admin);
        entryModule.approveKYC(alice);
        entryModule.approveKYC(bob);
        vm.stopPrank();
    }

    function testMemberModule_membersCannotPayInAdvance() public {
        vm.prank(alice);
        vm.expectRevert(MemberModule.MemberModule__InvalidDate.selector);
        userRouter.payRecurringContribution();
    }

    function testMemberModule_payRecurringContributionThrough5Years() public {
        uint256 expectedServiceIncrease = (CONTRIBUTION_AMOUNT * 27) / 100;

        for (uint256 i = 1; i < 5; i++) {
            Member memory testMember = takasureReserve.getMemberFromAddress(alice);

            uint256 totalContributionBeforePayment = testMember.totalContributions;
            uint256 totalServiceFeeBeforePayment = testMember.totalServiceFee;

            vm.warp(block.timestamp + YEAR);
            vm.roll(block.number + 1);

            vm.prank(alice);
            vm.expectEmit(true, true, true, true, address(memberModule));
            emit TakasureEvents.OnRecurringPayment(
                alice,
                testMember.memberId,
                i,
                CONTRIBUTION_AMOUNT,
                totalServiceFeeBeforePayment + expectedServiceIncrease
            );
            userRouter.payRecurringContribution();

            testMember = takasureReserve.getMemberFromAddress(alice);

            uint256 lastPaidYear = testMember.lastPaidYear;
            uint256 totalContributionAfterPayment = testMember.totalContributions;
            uint256 totalServiceFeeAfterPayment = testMember.totalServiceFee;

            assert(lastPaidYear == i);
            assert(
                totalContributionAfterPayment ==
                    totalContributionBeforePayment + CONTRIBUTION_AMOUNT
            );
            assert(
                totalServiceFeeAfterPayment ==
                    totalServiceFeeBeforePayment + expectedServiceIncrease
            );
        }

        vm.warp(block.timestamp + YEAR);
        vm.roll(block.number + 1);

        vm.prank(alice);
        vm.expectRevert(MemberModule.MemberModule__InvalidDate.selector);
        userRouter.payRecurringContribution();
    }

    function testMemberModule_defaultedMembersCanPayContribution() public {
        vm.warp(block.timestamp + YEAR + 15 days);
        vm.roll(block.number + 1);

        vm.expectEmit(true, true, false, false, address(memberModule));
        emit TakasureEvents.OnMemberDefaulted(1, alice);
        userRouter.defaultMember(alice);

        Member memory Alice = takasureReserve.getMemberFromAddress(alice);
        assert(Alice.memberState == MemberState.Defaulted);

        vm.warp(block.timestamp + 10 days);
        vm.roll(block.number + 1);

        vm.prank(alice);
        userRouter.payRecurringContribution();

        Alice = takasureReserve.getMemberFromAddress(alice);
        assert(Alice.memberState == MemberState.Active);
    }

    function testMemberModule_cannotPayAfterDefaultPeriod() public {
        vm.warp(block.timestamp + YEAR + 15 days);
        vm.roll(block.number + 1);

        vm.expectEmit(true, true, false, false, address(memberModule));
        emit TakasureEvents.OnMemberDefaulted(1, alice);
        userRouter.defaultMember(alice);

        Member memory Alice = takasureReserve.getMemberFromAddress(alice);
        assert(Alice.memberState == MemberState.Defaulted);

        vm.warp(block.timestamp + 15 days);
        vm.roll(block.number + 1);

        vm.prank(alice);
        vm.expectRevert(MemberModule.MemberModule__InvalidDate.selector);
        userRouter.payRecurringContribution();
    }
}
