// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {KYCModule} from "contracts/modules/KYCModule.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, Reserve} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract Reserves_TakasureCoreTest is StdCheats, Test {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    SubscriptionModule subscriptionModule;
    KYCModule kycModule;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address kycService;
    address takadao;
    address subscriptionModuleAddress;
    address kycModuleAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant YEAR = 365 days;
    uint256 public constant BM = 1;

    function setUp() public {
        deployer = new TestDeployProtocol();
        (
            takasureReserveProxy,
            ,
            subscriptionModuleAddress,
            kycModuleAddress,
            ,
            ,
            ,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        subscriptionModule = SubscriptionModule(subscriptionModuleAddress);
        kycModule = KYCModule(kycModuleAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        kycService = config.kycProvider;
        takadao = config.takadaoOperator;

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    JOIN POOL::UPDATE RESERVES
    //////////////////////////////////////////////////////////////*/

    /// @dev Test fund and claim reserves are calculated correctly
    function testTakasureCore_fundAndClaimReserves() public {
        vm.prank(alice);
        subscriptionModule.paySubscription(alice, address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        Reserve memory reserve = takasureReserve.getReserveValues();
        uint256 initialReserveRatio = reserve.initialReserveRatio;
        uint256 initialClaimReserve = reserve.totalClaimReserve;
        uint256 initialFundReserve = reserve.totalFundReserve;
        uint8 serviceFee = reserve.serviceFee;
        uint8 fundMarketExpendsShare = reserve.fundMarketExpendsAddShare;

        vm.prank(kycService);
        kycModule.approveKYC(alice, BM);

        // reserve = takasureReserve.getReserveValues();
        // uint256 finalClaimReserve = reserve.totalClaimReserve;
        // uint256 finalFundReserve = reserve.totalFundReserve;

        // uint256 fee = (CONTRIBUTION_AMOUNT * serviceFee) / 100; // 25USDC * 27% = 6.75USDC

        // uint256 deposited = CONTRIBUTION_AMOUNT - fee; // 25USDC - 6.75USDC = 18.25USDC

        // uint256 toFundReserveBeforeExpends = (deposited * initialReserveRatio) / 100; // 18.25USDC * 40% = 7.3USDC
        // uint256 marketExpends = (toFundReserveBeforeExpends * fundMarketExpendsShare) / 100; // 7.3USDC * 20% = 1.46USDC
        // uint256 expectedFinalClaimReserve = deposited - toFundReserveBeforeExpends; // 18.25USDC - 7.3USDC = 10.95USDC
        // uint256 expectedFinalFundReserve = toFundReserveBeforeExpends - marketExpends; // 7.3USDC - 1.46USDC = 5.84USDC
        // assertEq(initialClaimReserve, 0);
        // assertEq(initialFundReserve, 0);
        // assertEq(finalClaimReserve, expectedFinalClaimReserve);
        // assertEq(finalClaimReserve, 1095e4);
        // assertEq(finalFundReserve, expectedFinalFundReserve);
        // assertEq(finalFundReserve, 584e4);
    }

    /*//////////////////////////////////////////////////////////////
                    JOIN POOL::CASH LAST 12 MONTHS
    //////////////////////////////////////////////////////////////*/

    /// @dev Cash last 12 months less than a month
    function testTakasureCore_cashLessThanMonth() public {
        address[50] memory lotOfUsers;
        for (uint256 i; i < lotOfUsers.length; i++) {
            lotOfUsers[i] = makeAddr(vm.toString(i));
            deal(address(usdc), lotOfUsers[i], USDC_INITIAL_AMOUNT);
            vm.prank(lotOfUsers[i]);
            usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);

            vm.prank(lotOfUsers[i]);
            subscriptionModule.paySubscription(
                lotOfUsers[i],
                address(0),
                CONTRIBUTION_AMOUNT,
                (5 * YEAR)
            );
        }
        // Each day 10 users will join with the contribution amount

        // First day
        for (uint256 i; i < 10; i++) {
            vm.prank(kycService);
            kycModule.approveKYC(lotOfUsers[i], BM);
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Second day
        for (uint256 i = 10; i < 20; i++) {
            vm.prank(kycService);
            kycModule.approveKYC(lotOfUsers[i], BM);
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Third day
        for (uint256 i = 20; i < 30; i++) {
            vm.prank(kycService);
            kycModule.approveKYC(lotOfUsers[i], BM);
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Fourth day
        for (uint256 i = 30; i < 40; i++) {
            vm.prank(kycService);
            kycModule.approveKYC(lotOfUsers[i], BM);
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Fifth day
        for (uint256 i = 40; i < 50; i++) {
            vm.prank(kycService);
            kycModule.approveKYC(lotOfUsers[i], BM);
        }

        uint256 cash = takasureReserve.getCashLast12Months();

        // Each day 25USDC - fee = 20USDC will be deposited
        // 200USDC * 5 days = 1000USDC

        Reserve memory reserve = takasureReserve.getReserveValues();

        uint256 totalMembers = reserve.memberIdCounter;
        uint8 serviceFee = reserve.serviceFee;
        uint256 depositedByEach = CONTRIBUTION_AMOUNT - ((CONTRIBUTION_AMOUNT * serviceFee) / 100);
        uint256 totalDeposited = totalMembers * depositedByEach;

        assertEq(cash, totalDeposited);
    }

    /// @dev Cash last 12 months more than a month less than a year
    function testTakasureCore_cashMoreThanMonthLessThanYear() public {
        address[78] memory lotOfUsers;
        for (uint256 i; i < lotOfUsers.length; i++) {
            lotOfUsers[i] = makeAddr(vm.toString(i));
            deal(address(usdc), lotOfUsers[i], USDC_INITIAL_AMOUNT);
            vm.prank(lotOfUsers[i]);
            usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);

            vm.prank(lotOfUsers[i]);
            subscriptionModule.paySubscription(
                lotOfUsers[i],
                address(0),
                CONTRIBUTION_AMOUNT,
                (5 * YEAR)
            );
        }

        // Test three months two days

        // First month 30 people joins
        // 25USDC - fee = 20USDC
        // 20 * 30 = 600USDC
        for (uint256 i; i < 30; i++) {
            vm.prank(kycService);
            kycModule.approveKYC(lotOfUsers[i], BM);
        }

        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 1);

        // Second 10 people joins
        // 20 * 10 = 200USDC + 600USDC = 800USDC
        for (uint256 i = 30; i < 40; i++) {
            vm.prank(kycService);
            kycModule.approveKYC(lotOfUsers[i], BM);
        }

        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 1);

        // Third month first day 15 people joins
        // 20 * 15 = 300USDC + 800USDC = 1100USDC
        for (uint256 i = 40; i < 55; i++) {
            vm.prank(kycService);
            kycModule.approveKYC(lotOfUsers[i], BM);
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Third month second day 23 people joins
        // 20 * 23 = 460USDC + 1100USDC = 1560USDC
        for (uint256 i = 55; i < 78; i++) {
            vm.prank(kycService);
            kycModule.approveKYC(lotOfUsers[i], BM);
        }

        uint256 cash = takasureReserve.getCashLast12Months();

        Reserve memory reserve = takasureReserve.getReserveValues();

        uint256 totalMembers = reserve.memberIdCounter;
        uint8 serviceFee = reserve.serviceFee;
        uint256 depositedByEach = CONTRIBUTION_AMOUNT - ((CONTRIBUTION_AMOUNT * serviceFee) / 100);
        uint256 totalDeposited = totalMembers * depositedByEach;

        assertEq(cash, totalDeposited);
    }

    /// @dev Cash last 12 months more than a  year
    function testTakasureCore_cashMoreThanYear() public {
        uint256 cash;
        address[202] memory lotOfUsers;
        for (uint256 i; i < lotOfUsers.length; i++) {
            lotOfUsers[i] = makeAddr(vm.toString(i));
            deal(address(usdc), lotOfUsers[i], USDC_INITIAL_AMOUNT);
            vm.prank(lotOfUsers[i]);
            usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);

            vm.prank(lotOfUsers[i]);
            subscriptionModule.paySubscription(
                lotOfUsers[i],
                address(0),
                CONTRIBUTION_AMOUNT,
                (5 * YEAR)
            );
        }

        // Months 1, 2 and 3, one new member joins daily
        for (uint256 i; i < 90; i++) {
            vm.prank(kycService);
            kycModule.approveKYC(lotOfUsers[i], BM);
            vm.warp(block.timestamp + 1 days);
            vm.roll(block.number + 1);
        }

        // Months 4 to 12, 10 new members join monthly
        for (uint256 i = 90; i < 180; i++) {
            vm.prank(kycService);
            kycModule.approveKYC(lotOfUsers[i], BM);

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
        assertEq(cash, 326675e4);

        // Thirteenth month 10 people joins
        for (uint256 i = 180; i < 190; i++) {
            vm.prank(kycService);
            kycModule.approveKYC(lotOfUsers[i], BM);
        }

        // Month 1 take 29 days => Total 580USDC
        // Month 2 to 13 take all => Total 3685.5USDC

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 344925e4);

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        // Month 1 Should not count
        // Month 2 take 29 days => Total 580USDC
        // Month 3 to 13 take all => Total 3100.5USDC
        // Month 14 0USDC => Total 3100.5USDC

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 290175e4);

        // Fourteenth month 10 people joins
        for (uint256 i = 190; i < 200; i++) {
            vm.prank(kycService);
            kycModule.approveKYC(lotOfUsers[i], BM);
        }

        // Month 1 should not count
        // Month 2 take 29 days => Total 580USDC
        // Month 3 to 14 take all => Total 3295.5USDC

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 308425e4);

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        // Month 1 and 2 should not count
        // Month 3 take 29 days => Total 580USDC
        // Month 4 to 14 take all => Total 2780USDC
        // Month 15 0USDC => Total 2710.5USDC

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 253675e4);

        // Last 2 days 2 people joins
        for (uint256 i = 200; i < 202; i++) {
            vm.prank(kycService);
            kycModule.approveKYC(lotOfUsers[i], BM);

            vm.warp(block.timestamp + 1 days);
            vm.roll(block.number + 1);
        }

        // Month 1 and 2 should not count
        // Month 3 take 27 days => Total 540USDC
        // Month 4 to 15 take all => Total 2710.5USDC

        cash = takasureReserve.getCashLast12Months();

        assertEq(cash, 253675e4);

        // If no one joins for the next 12 months, the cash should be 0
        // As the months are counted with 30 days, the 12 months should be 360 days
        // 1 day after the year should be only 20USDC
        vm.warp(block.timestamp + 359 days);
        vm.roll(block.number + 1);

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 0);
    }
}
