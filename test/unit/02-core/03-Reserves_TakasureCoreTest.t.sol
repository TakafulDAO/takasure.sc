// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {UserRouter} from "contracts/router/UserRouter.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState, Reserve} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract Reserves_TakasureCoreTest is StdCheats, Test, SimulateDonResponse {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    EntryModule entryModule;
    UserRouter userRouter;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address admin;
    address kycService;
    address takadao;
    address entryModuleAddress;
    address userRouterAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    address public parent = makeAddr("parent");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
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
            ,
            ,
            userRouterAddress,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        entryModule = EntryModule(entryModuleAddress);
        userRouter = UserRouter(userRouterAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        kycService = config.kycProvider;
        takadao = config.takadaoOperator;

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(entryModuleAddress));

        vm.prank(takadao);
        entryModule.updateBmAddress();
    }

    /*//////////////////////////////////////////////////////////////
                    JOIN POOL::UPDATE RESERVES
    //////////////////////////////////////////////////////////////*/

    /// @dev Test fund and claim reserves are calculated correctly
    function testTakasureCore_fundAndClaimReserves() public {
        vm.prank(alice);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));

        Reserve memory reserve = takasureReserve.getReserveValues();
        uint256 initialReserveRatio = reserve.initialReserveRatio;
        uint256 initialClaimReserve = reserve.totalClaimReserve;
        uint256 initialFundReserve = reserve.totalFundReserve;
        uint8 serviceFee = reserve.serviceFee;
        uint8 fundMarketExpendsShare = reserve.fundMarketExpendsAddShare;

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        entryModule.approveKYC(alice);

        reserve = takasureReserve.getReserveValues();
        uint256 finalClaimReserve = reserve.totalClaimReserve;
        uint256 finalFundReserve = reserve.totalFundReserve;

        uint256 fee = (CONTRIBUTION_AMOUNT * serviceFee) / 100; // 25USDC * 27% = 6.75USDC

        uint256 deposited = CONTRIBUTION_AMOUNT - fee; // 25USDC - 6.75USDC = 18.25USDC

        uint256 toFundReserveBeforeExpends = (deposited * initialReserveRatio) / 100; // 18.25USDC * 40% = 7.3USDC
        uint256 marketExpends = (toFundReserveBeforeExpends * fundMarketExpendsShare) / 100; // 7.3USDC * 20% = 1.46USDC
        uint256 expectedFinalClaimReserve = deposited - toFundReserveBeforeExpends; // 18.25USDC - 7.3USDC = 10.95USDC
        uint256 expectedFinalFundReserve = toFundReserveBeforeExpends - marketExpends; // 7.3USDC - 1.46USDC = 5.84USDC
        assertEq(initialClaimReserve, 0);
        assertEq(initialFundReserve, 0);
        assertEq(finalClaimReserve, expectedFinalClaimReserve);
        assertEq(finalClaimReserve, 1095e4);
        assertEq(finalFundReserve, expectedFinalFundReserve);
        assertEq(finalFundReserve, 584e4);
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
            usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);

            vm.prank(lotOfUsers[i]);
            userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));
        }
        // Each day 10 users will join with the contribution amount

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        // First day
        for (uint256 i; i < 10; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Second day
        for (uint256 i = 10; i < 20; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Third day
        for (uint256 i = 20; i < 30; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Fourth day
        for (uint256 i = 30; i < 40; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Fifth day
        for (uint256 i = 40; i < 50; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
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
            usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);

            vm.prank(lotOfUsers[i]);
            userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        // Test three months two days

        // First month 30 people joins
        // 25USDC - fee = 20USDC
        // 20 * 30 = 600USDC
        for (uint256 i; i < 30; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 1);

        // Second 10 people joins
        // 20 * 10 = 200USDC + 600USDC = 800USDC
        for (uint256 i = 30; i < 40; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        vm.warp(block.timestamp + 31 days);
        vm.roll(block.number + 1);

        // Third month first day 15 people joins
        // 20 * 15 = 300USDC + 800USDC = 1100USDC
        for (uint256 i = 40; i < 55; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // Third month second day 23 people joins
        // 20 * 23 = 460USDC + 1100USDC = 1560USDC
        for (uint256 i = 55; i < 78; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
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
        address[260] memory lotOfUsers;
        for (uint256 i; i < lotOfUsers.length; i++) {
            lotOfUsers[i] = makeAddr(vm.toString(i));
            deal(address(usdc), lotOfUsers[i], USDC_INITIAL_AMOUNT);
            vm.prank(lotOfUsers[i]);
            usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);

            vm.prank(lotOfUsers[i]);
            userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));
        }

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        // Months 1, 2 and 3, one new member joins daily
        // 90 users 25USDC - fee = 25USDC - 6.75USDC = 18.25USDC
        // 18.25USDC * 90 = 1642.5USDC
        for (uint256 i; i < 90; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
            vm.warp(block.timestamp + 1 days);
            vm.roll(block.number + 1);
        }

        // Month 4 10 people joins
        // 18.25USDC * 10 = 182.5USDC + 1642.5USDC = 1825USDC
        for (uint256 i = 90; i < 100; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        // Month 5 10 people joins
        // 18.25USDC * 10 = 182.5USDC + 1825USDC = 2007.5USDC
        for (uint256 i = 100; i < 110; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        // Month 6 10 people joins
        // 18.25USDC * 10 = 182.5USDC + 2007.5USDC = 2190USDC
        for (uint256 i = 110; i < 120; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        // Month 7 10 people joins
        // 18.25USDC * 10 = 182.5USDC + 2190USDC = 2372.5USDC
        for (uint256 i = 120; i < 130; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        // Month 8 10 people joins
        // 18.25USDC * 10 = 182.5USDC + 2372.5USDC = 2555USDC
        for (uint256 i = 130; i < 140; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        // Month 9 10 people joins
        // 18.25USDC * 10 = 182.5USDC + 2555USDC = 2737.5USDC
        for (uint256 i = 140; i < 150; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        // Month 10 10 people joins
        // 18.25USDC * 10 = 182.5USDC + 2737.5USDC = 2920USDC
        for (uint256 i = 150; i < 160; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        // Month 11 10 people joins
        // 18.25USDC * 10 = 182.5USDC + 2920USDC = 3102.5USDC
        for (uint256 i = 160; i < 170; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        // Month 12 10 people joins
        // 18.25USDC * 10 = 182.5USDC + 3102.5USDC = 3285USDC
        for (uint256 i = 170; i < 180; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        // 12 months cash
        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 328500e4);

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        // First day of the thirteenth month 10 people joins
        // Should be past cash minus one day of the first month
        // The first day of the first month was 18.25USDC
        // 3285USDC - 18.25USDC = 3266.75USDC
        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 326675e4);

        // Thirteenth month 10 people joins
        // 18.25USDC * 10 = 182.5USDC + 3266.75USDC = 3449.25USDC
        for (uint256 i = 180; i < 190; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 344925e4);

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1);

        // 14 month
        // Previous cash minus month 1
        // Month 1 was 18.25USDC * 30 days = 547.5USDC
        // 3449.25USDC - 547.5USDC = 2901.75USDC

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 290175e4);

        // Fourteenth month 10 people joins
        for (uint256 i = 190; i < 200; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
        }

        // Previous cash + 182.5 = 3084.25USDC
        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 308425e4);

        // Join 1 daily for 5 days
        // Should always stay the same because the one joining this day
        // Is the same amount as the day we are removing
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 306600e4);

        vm.prank(admin);
        entryModule.approveKYC(lotOfUsers[200]);

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 308425e4);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 306600e4);

        vm.prank(admin);
        entryModule.approveKYC(lotOfUsers[201]);

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 308425e4);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 306600e4);

        vm.prank(admin);
        entryModule.approveKYC(lotOfUsers[202]);

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 308425e4);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 306600e4);

        vm.prank(admin);
        entryModule.approveKYC(lotOfUsers[203]);

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 308425e4);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 306600e4);

        vm.prank(admin);
        entryModule.approveKYC(lotOfUsers[204]);

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 308425e4);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 306600e4);

        // Join 1 hourly for 2 days
        // 48 people join in 2 days
        // 18.25USDC * 48 = 876USDC + 3066USDC = 3942USDC - (2 days)
        // Those 2 days are 18.25USDC * 2 = 36.5USDC
        // 3942USDC - 36.5USDC = 3905.5USDC
        for (uint256 i = 205; i < 205 + 48; i++) {
            vm.prank(admin);
            entryModule.approveKYC(lotOfUsers[i]);
            vm.warp(block.timestamp + 1 hours);
            vm.roll(block.number + 1);
        }

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 390550e4);

        // If no one joins for the next 12 months, the cash should be 0
        // As the months are counted with 30 days, the 12 months should be 360 days
        // 1 day after the year should be only 20USDC

        vm.warp(block.timestamp + 359 days);
        vm.roll(block.number + 1);

        cash = takasureReserve.getCashLast12Months();
        assertEq(cash, 0);
    }
}
