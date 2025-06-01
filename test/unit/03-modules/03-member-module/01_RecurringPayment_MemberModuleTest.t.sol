// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {KYCModule} from "contracts/modules/KYCModule.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";
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
    SubscriptionModule subscriptionModule;
    KYCModule kycModule;
    MemberModule memberModule;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address admin;
    address kycService;
    address takadao;
    address subscriptionModuleAddress;
    address kycModuleAddress;
    address memberModuleAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
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
            subscriptionModuleAddress,
            kycModuleAddress,
            memberModuleAddress,
            ,
            ,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        subscriptionModule = SubscriptionModule(subscriptionModuleAddress);
        memberModule = MemberModule(memberModuleAddress);
        kycModule = KYCModule(kycModuleAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        kycService = config.kycProvider;
        takadao = config.takadaoOperator;

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.startPrank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(subscriptionModuleAddress));
        bmConsumerMock.setNewRequester(address(kycModuleAddress));
        vm.stopPrank();

        vm.startPrank(takadao);
        subscriptionModule.updateBmAddress();
        kycModule.updateBmAddress();
        vm.stopPrank();

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(memberModule), USDC_INITIAL_AMOUNT);

        subscriptionModule.paySubscription(alice, address(0), CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.startPrank(admin);
        kycModule.approveKYC(alice);
        vm.stopPrank();
    }

    function testMemberModule_payRecurringContributionThrough5Years() public {
        uint256 expectedServiceIncrease = (CONTRIBUTION_AMOUNT * 27) / 100;

        for (uint256 i = 0; i < 5; i++) {
            Member memory testMember = takasureReserve.getMemberFromAddress(alice);

            uint256 lastYearStartDateBefore = testMember.lastPaidYearStartDate;
            uint256 totalContributionBeforePayment = testMember.totalContributions;
            uint256 totalServiceFeeBeforePayment = testMember.totalServiceFee;

            vm.warp(block.timestamp + YEAR);
            vm.roll(block.number + 1);

            vm.startPrank(alice);
            vm.expectEmit(true, true, true, true, address(memberModule));
            emit TakasureEvents.OnRecurringPayment(
                alice,
                testMember.memberId,
                lastYearStartDateBefore + 365 days,
                CONTRIBUTION_AMOUNT,
                totalServiceFeeBeforePayment + expectedServiceIncrease
            );
            memberModule.payRecurringContribution(alice);
            vm.stopPrank();

            testMember = takasureReserve.getMemberFromAddress(alice);

            uint256 lastYearStartDateAfter = testMember.lastPaidYearStartDate;
            uint256 totalContributionAfterPayment = testMember.totalContributions;
            uint256 totalServiceFeeAfterPayment = testMember.totalServiceFee;

            assert(lastYearStartDateAfter == lastYearStartDateBefore + 365 days);
            assert(
                totalContributionAfterPayment ==
                    totalContributionBeforePayment + CONTRIBUTION_AMOUNT
            );
            assert(
                totalServiceFeeAfterPayment ==
                    totalServiceFeeBeforePayment + expectedServiceIncrease
            );
        }
    }

    function testMemberModule_defaultedMembersCanPayContribution() public {
        vm.warp(block.timestamp + YEAR + 15 days);
        vm.roll(block.number + 1);

        vm.expectEmit(true, true, false, false, address(memberModule));
        emit TakasureEvents.OnMemberDefaulted(1, alice);
        memberModule.defaultMember(alice);

        Member memory Alice = takasureReserve.getMemberFromAddress(alice);
        assert(Alice.memberState == MemberState.Defaulted);

        vm.warp(block.timestamp + 10 days);
        vm.roll(block.number + 1);

        vm.prank(alice);
        memberModule.payRecurringContribution(alice);
        Alice = takasureReserve.getMemberFromAddress(alice);
        assert(Alice.memberState == MemberState.Active);
    }
}
