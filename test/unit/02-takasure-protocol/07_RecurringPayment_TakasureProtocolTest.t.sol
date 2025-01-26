// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasureReserve} from "test/utils/TestDeployTakasureReserve.s.sol";
import {DeployConsumerMocks} from "test/utils/DeployConsumerMocks.s.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/takasure/core/TakasureReserve.sol";
import {JoinModule} from "contracts/takasure/modules/JoinModule.sol";
import {MembersModule} from "contracts/takasure/modules/MembersModule.sol";
import {UserRouter} from "contracts/takasure/router/UserRouter.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract payRecurringContribution_TakasureProtocolTest is StdCheats, Test, SimulateDonResponse {
    TestDeployTakasureReserve deployer;
    DeployConsumerMocks mockDeployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    JoinModule joinModule;
    MembersModule membersModule;
    UserRouter userRouter;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address admin;
    address kycService;
    address takadao;
    address joinModuleAddress;
    address membersModuleAddress;
    address userRouterAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 150e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new TestDeployTakasureReserve();
        (
            takasureReserveProxy,
            joinModuleAddress,
            membersModuleAddress,
            ,
            userRouterAddress,
            contributionTokenAddress,
            helperConfig
        ) = deployer.run();

        joinModule = JoinModule(joinModuleAddress);
        membersModule = MembersModule(membersModuleAddress);
        userRouter = UserRouter(userRouterAddress);

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

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(membersModule), USDC_INITIAL_AMOUNT);

        userRouter.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank;

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.startPrank(admin);
        joinModule.setKYCStatus(alice);
        vm.stopPrank;
    }

    function testMembersModule_payRecurringContributionThrough5Years() public {
        uint256 expectedServiceIncrease = (CONTRIBUTION_AMOUNT * 22) / 100;

        for (uint256 i = 0; i < 5; i++) {
            Member memory testMember = takasureReserve.getMemberFromAddress(alice);

            uint256 lastYearStartDateBefore = testMember.lastPaidYearStartDate;
            uint256 totalContributionBeforePayment = testMember.totalContributions;
            uint256 totalServiceFeeBeforePayment = testMember.totalServiceFee;

            vm.warp(block.timestamp + YEAR);
            vm.roll(block.number + 1);

            vm.startPrank(alice);
            vm.expectEmit(true, true, true, true, address(membersModule));
            emit TakasureEvents.OnRecurringPayment(
                alice,
                testMember.memberId,
                lastYearStartDateBefore + 365 days,
                CONTRIBUTION_AMOUNT,
                totalServiceFeeBeforePayment + expectedServiceIncrease
            );
            userRouter.payRecurringContribution();
            vm.stopPrank;

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
}
