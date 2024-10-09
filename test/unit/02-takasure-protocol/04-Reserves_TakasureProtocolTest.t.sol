// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasureReserve} from "test/utils/TestDeployTakasureReserve.s.sol";
import {DeployConsumerMocks} from "test/utils/DeployConsumerMocks.s.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/takasure/core/TakasureReserve.sol";
import {JoinModule} from "contracts/takasure/modules/JoinModule.sol";
import {TSTokenSize} from "contracts/token/TSTokenSize.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState, NewReserve} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract Reserves_TakasureProtocolTest is StdCheats, Test, SimulateDonResponse {
    TestDeployTakasureReserve deployer;
    DeployConsumerMocks mockDeployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    JoinModule joinModule;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address admin;
    address kycService;
    address takadao;
    address joinModuleAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new TestDeployTakasureReserve();
        (
            takasureReserveProxy,
            joinModuleAddress,
            ,
            contributionTokenAddress,
            helperConfig
        ) = deployer.run();

        joinModule = JoinModule(joinModuleAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        kycService = config.kycProvider;
        takadao = config.takadaoOperator;

        mockDeployer = new DeployConsumerMocks();
        bmConsumerMock = mockDeployer.run();

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(msg.sender);
        bmConsumerMock.setNewRequester(address(joinModuleAddress));

        vm.prank(takadao);
        joinModule.updateBmAddress();
    }

    /*//////////////////////////////////////////////////////////////
                    JOIN POOL::UPDATE RESERVES
    //////////////////////////////////////////////////////////////*/

    /// @dev Test fund and claim reserves are calculated correctly
    function testTakasureReserve_fundAndClaimReserves() public {
        vm.prank(admin);
        joinModule.setKYCStatus(alice);

        NewReserve memory reserve = takasureReserve.getReserveValues();
        uint256 initialReserveRatio = reserve.initialReserveRatio;
        uint256 initialClaimReserve = reserve.totalClaimReserve;
        uint256 initialFundReserve = reserve.totalFundReserve;
        uint8 serviceFee = reserve.serviceFee;
        uint8 fundMarketExpendsShare = reserve.fundMarketExpendsAddShare;

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(alice);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        reserve = takasureReserve.getReserveValues();
        uint256 finalClaimReserve = reserve.totalClaimReserve;
        uint256 finalFundReserve = reserve.totalFundReserve;

        uint256 fee = (CONTRIBUTION_AMOUNT * serviceFee) / 100; // 25USDC * 22% = 5.5USDC

        uint256 deposited = CONTRIBUTION_AMOUNT - fee; // 25USDC - 5.5USDC = 19.5USDC

        uint256 toFundReserveBeforeExpends = (deposited * initialReserveRatio) / 100; // 19.5USDC * 40% = 7.8USDC
        uint256 marketExpends = (toFundReserveBeforeExpends * fundMarketExpendsShare) / 100; // 7.8USDC * 20% = 1.56USDC
        uint256 expectedFinalClaimReserve = deposited - toFundReserveBeforeExpends; // 19.5USDC - 7.8USDC = 11.7USDC
        uint256 expectedFinalFundReserve = toFundReserveBeforeExpends - marketExpends; // 7.8USDC - 1.56USDC = 6.24USDC
        assertEq(initialClaimReserve, 0);
        assertEq(initialFundReserve, 0);
        assertEq(finalClaimReserve, expectedFinalClaimReserve);
        assertEq(finalClaimReserve, 117e5);
        assertEq(finalFundReserve, expectedFinalFundReserve);
        assertEq(finalFundReserve, 624e4);
    }

    /*//////////////////////////////////////////////////////////////
                    JOIN POOL::CASH LAST 12 MONTHS
    //////////////////////////////////////////////////////////////*/

    /// @dev Cash last 12 months less than a month
    function testTakasureReserve_cashLessThanMonth() public {
        address[50] memory lotOfUsers;
        for (uint256 i; i < lotOfUsers.length; i++) {
            lotOfUsers[i] = makeAddr(vm.toString(i));
            deal(address(usdc), lotOfUsers[i], USDC_INITIAL_AMOUNT);
            vm.prank(lotOfUsers[i]);
            usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);

            vm.prank(admin);
            joinModule.setKYCStatus(lotOfUsers[i]);
        }
        // Each day 10 users will join with the contribution amount

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        // First day
        for (uint256 i; i < 10; i++) {
            vm.prank(lotOfUsers[i]);
            joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Second day
        for (uint256 i = 10; i < 20; i++) {
            vm.prank(lotOfUsers[i]);
            joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Third day
        for (uint256 i = 20; i < 30; i++) {
            vm.prank(lotOfUsers[i]);
            joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Fourth day
        for (uint256 i = 30; i < 40; i++) {
            vm.prank(lotOfUsers[i]);
            joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Fifth day
        for (uint256 i = 40; i < 50; i++) {
            vm.prank(lotOfUsers[i]);
            joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        uint256 cash = takasureReserve.getCashLast12Months();

        // Each day 25USDC - fee = 20USDC will be deposited
        // 200USDC * 5 days = 1000USDC

        NewReserve memory reserve = takasureReserve.getReserveValues();

        uint256 totalMembers = reserve.memberIdCounter;
        uint8 serviceFee = reserve.serviceFee;
        uint256 depositedByEach = CONTRIBUTION_AMOUNT - ((CONTRIBUTION_AMOUNT * serviceFee) / 100);
        uint256 totalDeposited = totalMembers * depositedByEach;

        assertEq(cash, totalDeposited);
    }

    /// @dev Cash last 12 months more than a month less than a year
    function testTakasureReserve_cashMoreThanMonthLessThanYear() public {
        address[78] memory lotOfUsers;
        for (uint256 i; i < lotOfUsers.length; i++) {
            lotOfUsers[i] = makeAddr(vm.toString(i));
            deal(address(usdc), lotOfUsers[i], USDC_INITIAL_AMOUNT);
            vm.prank(lotOfUsers[i]);
            usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);

            vm.prank(admin);
            joinModule.setKYCStatus(lotOfUsers[i]);
        }

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        // Test three months two days

        // First month 30 people joins
        // 25USDC - fee = 20USDC
        // 20 * 30 = 600USDC
        for (uint256 i; i < 30; i++) {
            vm.prank(lotOfUsers[i]);
            joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 1);

        // Second 10 people joins
        // 20 * 10 = 200USDC + 600USDC = 800USDC
        for (uint256 i = 30; i < 40; i++) {
            vm.prank(lotOfUsers[i]);
            joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 1);

        // Third month first day 15 people joins
        // 20 * 15 = 300USDC + 800USDC = 1100USDC
        for (uint256 i = 40; i < 55; i++) {
            vm.prank(lotOfUsers[i]);
            joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Third month second day 23 people joins
        // 20 * 23 = 460USDC + 1100USDC = 1560USDC
        for (uint256 i = 55; i < 78; i++) {
            vm.prank(lotOfUsers[i]);
            joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        uint256 cash = takasureReserve.getCashLast12Months();

        NewReserve memory reserve = takasureReserve.getReserveValues();

        uint256 totalMembers = reserve.memberIdCounter;
        uint8 serviceFee = reserve.serviceFee;
        uint256 depositedByEach = CONTRIBUTION_AMOUNT - ((CONTRIBUTION_AMOUNT * serviceFee) / 100);
        uint256 totalDeposited = totalMembers * depositedByEach;

        assertEq(cash, totalDeposited);
    }

    /// @dev Cash last 12 months more than a  year
    function testTakasureReserve_cashMoreThanYear() public {
        uint256 cash;
        address[202] memory lotOfUsers;
        for (uint256 i; i < lotOfUsers.length; i++) {
            lotOfUsers[i] = makeAddr(vm.toString(i));
            deal(address(usdc), lotOfUsers[i], USDC_INITIAL_AMOUNT);
            vm.prank(lotOfUsers[i]);
            usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);

            vm.prank(admin);
            joinModule.setKYCStatus(lotOfUsers[i]);
        }

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        // Months 1, 2 and 3, one new member joins daily
        for (uint256 i; i < 90; i++) {
            vm.prank(lotOfUsers[i]);
            joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));
            vm.warp(block.timestamp + 1 days);
            vm.roll(block.number + 1);
        }

        // Months 4 to 12, 10 new members join monthly
        for (uint256 i = 90; i < 180; i++) {
            vm.prank(lotOfUsers[i]);
            joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

            // End of the month
            if (
                i == 99 ||
                i == 109 ||
                i == 119 ||
                i == 129 ||
                i == 139 ||
                i == 149 ||
                i == 159 ||
                i == 169 ||
                i == 179
            ) {
                vm.warp(block.timestamp + 30 days);
                vm.roll(block.number + 1);
            }
        }

        // Month 1 take 29 days => Total 580USDC
        // Months 1 to 12 take all => Total 3490.5USDC
        // Month 13 0USDC => Total 3490.5USDC

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 34905e5);

        // Thirteenth month 10 people joins
        for (uint256 i = 180; i < 190; i++) {
            vm.prank(lotOfUsers[i]);
            joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        // Month 1 take 29 days => Total 580USDC
        // Month 2 to 13 take all => Total 3685.5USDC

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 36855e5);

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        // Month 1 Should not count
        // Month 2 take 29 days => Total 580USDC
        // Month 3 to 13 take all => Total 3100.5USDC
        // Month 14 0USDC => Total 3100.5USDC

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 31005e5);

        // Fourteenth month 10 people joins
        for (uint256 i = 190; i < 200; i++) {
            vm.prank(lotOfUsers[i]);
            joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        // Month 1 should not count
        // Month 2 take 29 days => Total 580USDC
        // Month 3 to 14 take all => Total 3295.5USDC

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 32955e5);

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        // Month 1 and 2 should not count
        // Month 3 take 29 days => Total 580USDC
        // Month 4 to 14 take all => Total 2780USDC
        // Month 15 0USDC => Total 2710.5USDC

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 27105e5);

        // Last 2 days 2 people joins
        for (uint256 i = 200; i < 202; i++) {
            vm.prank(lotOfUsers[i]);
            joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

            vm.warp(block.timestamp + 1 days);
            vm.roll(block.number + 1);
        }

        // Month 1 and 2 should not count
        // Month 3 take 27 days => Total 540USDC
        // Month 4 to 15 take all => Total 2710.5USDC

        cash = takasureReserve.getCashLast12Months();

        assertEq(cash, 27105e5);

        // If no one joins for the next 12 months, the cash should be 0
        // As the months are counted with 30 days, the 12 months should be 360 days
        // 1 day after the year should be only 20USDC
        vm.warp(block.timestamp + 359 days);
        vm.roll(block.number + 1);

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 0);
    }
}
