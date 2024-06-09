// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {ReserveMathLibHarness} from "../../helpers/harness/ReserveMathLibHarness.t.sol";

contract ReserveMathLibTest is Test {
    ReserveMathLibHarness public reserveMathLibHarness;

    function setUp() public {
        reserveMathLibHarness = new ReserveMathLibHarness();
    }

    /*//////////////////////////////////////////////////////////////
                      UPDATE PROFORMA FUND RESERVE
    //////////////////////////////////////////////////////////////*/

    function testReserveMathLib__updateProFormaFundReserve_newOne() public view {
        uint256 currentProFormaFundReserve = 0;
        uint256 memberNetContribution = 25000000;
        uint256 currentDynamicReserveRatio = 40;

        // updatedProFormaFundReserve = currentProFormaFundReserve + ((memberNetContribution * currentDynamicReserveRatio) / 100);
        // updatedProFormaFundReserve = 0 + ((25_000_000 * 40) / 100) = 10_000_000

        uint256 expectedProFormaFundReserve = 10000000;

        uint256 updatedProFormaFundReserve = reserveMathLibHarness
            .exposed__updateProFormaFundReserve(
                currentProFormaFundReserve,
                memberNetContribution,
                currentDynamicReserveRatio
            );

        assertEq(updatedProFormaFundReserve, expectedProFormaFundReserve);
    }

    function testReserveMathLib__updateProFormaFundReserve_alreadySomeValue() public view {
        uint256 currentProFormaFundReserve = 10000000;
        uint256 memberNetContribution = 50000000;
        uint256 currentDynamicReserveRatio = 43;

        // updatedProFormaFundReserve = currentProFormaFundReserve + ((memberNetContribution * currentDynamicReserveRatio) / 100);
        // updatedProFormaFundReserve = 10_000_000 + ((50_000_000 * 43) / 100) = 31_500_000

        uint256 expectedProFormaFundReserve = 31500000;

        uint256 updatedProFormaFundReserve = reserveMathLibHarness
            .exposed__updateProFormaFundReserve(
                currentProFormaFundReserve,
                memberNetContribution,
                currentDynamicReserveRatio
            );

        assertEq(updatedProFormaFundReserve, expectedProFormaFundReserve);
    }

    /*//////////////////////////////////////////////////////////////
                      UPDATE PROFORMA CLAIM RESERVE
    //////////////////////////////////////////////////////////////*/

    function testReserveMathLib__updateProFormaClaimReserve_newOne() public view {
        uint256 currentProFormaClaimReserve = 0;
        uint256 memberNetContribution = 25e6;
        uint8 wakalaFee = 20;
        uint256 initialDynamicReserveRatio = 40;

        // math:
        // Should be = currentProFormaClaimReserve + (memberNetContribution * (1 - wakalaFee) * (1 - initialDynamicReserveRatio))
        // 0 + (25_000_000 * (1 - 0.2) * (1 - 0.4) = 25_000_000 * 0.8 * 0.6 = 12_000_000

        // Solidity = currentProFormaClaimReserve + (memberNetContribution * (100 - wakalaFee) * (100 - initialDynamicReserveRatio) / 1_000)
        // 0 + (25_000_000 * (100 - 20) * (100 - 40) / 1_000) = 25_000_000 * 80 * 60 / 1_000 = 120_000_000_000 / 1_000 = 12_000_000

        uint256 expectedProFormaFundReserve = 12e6; // 12000000

        uint256 updatedProFormaFundReserve = reserveMathLibHarness
            .exposed__updateProFormaClaimReserve(
                currentProFormaClaimReserve,
                memberNetContribution,
                wakalaFee,
                initialDynamicReserveRatio
            );

        assertEq(updatedProFormaFundReserve, expectedProFormaFundReserve);
    }

    function testReserveMathLib__updateProFormaClaimReserve_alreadySomeValue() public view {
        uint256 currentProFormaClaimReserve = 10e6;
        uint256 memberNetContribution = 50e6;
        uint8 wakalaFee = 20;
        uint256 initialDynamicReserveRatio = 40;

        // math:
        // Should be = currentProFormaClaimReserve + (memberNetContribution * (1 - wakalaFee) * (1 - initialDynamicReserveRatio))
        // 10_000_000 + (50_000_000 * (1 - 0.2) * (1 - 0.4) = 10_000_000 + (50_000_000 * 0.8 * 0.6) = 10_000_000 + 24_000_000 = 34_000_000

        // Solidity = currentProFormaClaimReserve + (memberNetContribution * (100 - wakalaFee) * (100 - initialDynamicReserveRatio) / 1_000)
        // 10_000_000 + (50_000_000 * (100 - 20) * (100 - 40) / 1_000) = 10_000_000 + (50_000_000 * 80 * 60 / 1_000) = 10_000_000 + (240_000_000_000 / 1_000)
        // 10_000_000 + 24_000_000 = 34_000_000

        uint256 expectedProFormaFundReserve = 34e6;

        uint256 updatedProFormaFundReserve = reserveMathLibHarness
            .exposed__updateProFormaClaimReserve(
                currentProFormaClaimReserve,
                memberNetContribution,
                wakalaFee,
                initialDynamicReserveRatio
            );

        assertEq(updatedProFormaFundReserve, expectedProFormaFundReserve);
    }

    /*//////////////////////////////////////////////////////////////
                 DYNAMIC RESERVE RATIO SHORTFALL METHOD
    //////////////////////////////////////////////////////////////*/

    /// @dev The DRR should remain the same if the fund reserve is greater than the pro forma fund reserve
    function testReserveMathLib__calculateDynamicReserveRatioReserveShortfallMethod_noShortfall_1()
        public
        view
    {
        uint256 currentDynamicReserveRatio = 40;
        uint256 proFormaFundReserve = 10000000;
        uint256 fundReserve = 25000000;
        uint256 cashFlowLastPeriod = 25000000;

        // fundReserveShortfall = proFormaFundReserve - fundReserve
        // fundReserveShortfall = 10_000_000 - 25_000_000 = -15_000_000 < 0 => DRR remains the same

        uint256 updatedDynamicReserveRatio = reserveMathLibHarness
            .exposed__calculateDynamicReserveRatioReserveShortfallMethod(
                currentDynamicReserveRatio,
                proFormaFundReserve,
                fundReserve,
                cashFlowLastPeriod
            );

        assertEq(updatedDynamicReserveRatio, currentDynamicReserveRatio);
    }

    /// @dev The DRR should remain the same if the fund reserve is greater than the pro forma fund reserve
    function testReserveMathLib__calculateDynamicReserveRatioReserveShortfallMethod_noShortfall_2()
        public
        view
    {
        uint256 currentDynamicReserveRatio = 40;
        uint256 proFormaFundReserve = 100000000;
        uint256 fundReserve = 25000000;
        uint256 cashFlowLastPeriod = 0;

        // cashFlowLastPeriod = 0 => DRR remains the same

        uint256 updatedDynamicReserveRatio = reserveMathLibHarness
            .exposed__calculateDynamicReserveRatioReserveShortfallMethod(
                currentDynamicReserveRatio,
                proFormaFundReserve,
                fundReserve,
                cashFlowLastPeriod
            );

        assertEq(updatedDynamicReserveRatio, currentDynamicReserveRatio);
    }

    /// @dev The DRR should be updated if the fund reserve is less than the pro forma fund reserve and the possible DRR is less than 100
    function testReserveMathLib__calculateDynamicReserveRatioReserveShortfallMethod_shortfallLessThan100()
        public
        view
    {
        uint256 currentDynamicReserveRatio = 85;
        uint256 proFormaFundReserve = 257e5; // 25700000
        uint256 fundReserve = 25e6; // 25000000
        uint256 cashFlowLastPeriod_1 = 200e6; // 200000000
        uint256 cashFlowLastPeriod_2 = 30e6; // 30000000

        // fundReserveShortfall = proFormaFundReserve - fundReserve;
        // fundReserveShortfall = 25_700_000 - 25_000_000 = 700_000 > 0
        // cashFlowLastPeriod_1 = 200_000_000 > 0
        // cashFlowLastPeriod_2 = 30_000_000 > 0

        // possibleDRR_1 = currentDynamicReserveRatio + (fundReserveShortfall * 100 / cashFlowLastPeriod_1);
        // possibleDRR_1 = 85 + (70_000_000 / 25_000_000) = 85 < 100 => Updated DRR = 85
        // expectedDRR_1 = 85

        // possibleDRR_2 = currentDynamicReserveRatio + (fundReserveShortfall * 100 / cashFlowLastPeriod_2);
        // possibleDRR_2 = 85 + (70_000_000 / 30_000_000) = 85 < 100 => Updated DRR = 85
        // expectedDRR_2 = 87

        uint256 expectedDRR_1 = 85;
        uint256 expectedDRR_2 = 87;

        uint256 updatedDynamicReserveRatio_1 = reserveMathLibHarness
            .exposed__calculateDynamicReserveRatioReserveShortfallMethod(
                currentDynamicReserveRatio,
                proFormaFundReserve,
                fundReserve,
                cashFlowLastPeriod_1
            );

        uint256 updatedDynamicReserveRatio_2 = reserveMathLibHarness
            .exposed__calculateDynamicReserveRatioReserveShortfallMethod(
                currentDynamicReserveRatio,
                proFormaFundReserve,
                fundReserve,
                cashFlowLastPeriod_2
            );

        assertEq(updatedDynamicReserveRatio_1, expectedDRR_1);
        assertEq(updatedDynamicReserveRatio_2, expectedDRR_2);
    }

    /// @dev The DRR should be updated if the fund reserve is less than the pro forma fund reserve and the possible DRR is greater than 100
    function testReserveMathLib__calculateDynamicReserveRatioReserveShortfallMethod_shortfallGreaterThan100()
        public
        view
    {
        uint256 currentDynamicReserveRatio = 40;
        uint256 proFormaFundReserve = 100000000;
        uint256 fundReserve = 25000000;
        uint256 cashFlowLastPeriod = 25000000;

        // fundReserveShortfall = proFormaFundReserve - fundReserve;
        // fundReserveShortfall = 100_000_000 - 25_000_000 = 75_000_000 > 0
        // cashFlowLastPeriod = 25_000_000 > 0

        // possibleDRR = currentDynamicReserveRatio + (fundReserveShortfall * 100 / cashFlowLastPeriod);
        // possibleDRR = 40 + (75_000_000 / 25_000_000) = 340 > 100 => Updated DRR = 100
        // expectedDRR = 100

        uint256 expectedDRR = 100;

        uint256 updatedDynamicReserveRatio = reserveMathLibHarness
            .exposed__calculateDynamicReserveRatioReserveShortfallMethod(
                currentDynamicReserveRatio,
                proFormaFundReserve,
                fundReserve,
                cashFlowLastPeriod
            );

        assertEq(updatedDynamicReserveRatio, expectedDRR);
    }

    /*//////////////////////////////////////////////////////////////
                          BMA CASHFLOW METHOD
    //////////////////////////////////////////////////////////////*/

    struct BmaCashflowMethodTest {
        uint256 totalClaimReserves;
        uint256 totalFundReserves;
        uint256 bmaFundReserveShares;
        uint256 proFormaClaimReserve;
        uint256 bmaInflowAssumption;
        uint256 expectedBma;
    }

    /// @dev Test the calculation of BMA using the cash flow method
    function testReserveMathLib__calculateBmaCashflowMethod() public view {
        BmaCashflowMethodTest[] memory testInputs = new BmaCashflowMethodTest[](2);

        testInputs[0] = BmaCashflowMethodTest({
            totalClaimReserves: 10e6, // 10000000
            totalFundReserves: 15e6, // 15000000
            bmaFundReserveShares: 70, // 70%
            proFormaClaimReserve: 12e6, // 12000000
            bmaInflowAssumption: 12e6, // 12000000
            expectedBma: 94 // 94%
        });

        testInputs[1] = BmaCashflowMethodTest({
            totalClaimReserves: 150e6, // 150000000
            totalFundReserves: 250e6, // 25000000
            bmaFundReserveShares: 70, // 70%
            proFormaClaimReserve: 584e5, // 58400000
            bmaInflowAssumption: 384e5, // 38400000
            expectedBma: 100 // 100%
        });

        for (uint256 i = 0; i < testInputs.length; i++) {
            BmaCashflowMethodTest memory testInput = testInputs[i];

            uint256 bma = reserveMathLibHarness.exposed_calculateBmaCashFlowMethod(
                testInput.totalClaimReserves,
                testInput.totalFundReserves,
                testInput.bmaFundReserveShares,
                testInput.proFormaClaimReserve,
                testInput.bmaInflowAssumption
            );

            assertEq(bma, testInput.expectedBma);
        }
    }

    /*//////////////////////////////////////////////////////////////
                               DAY & MONTH
    //////////////////////////////////////////////////////////////*/

    /// @dev Test the calculation of days passed
    function testReserveMathLib__calculateDaysPassed() public view {
        uint256 finalDayTimestamp = 1716446853; // Thu May 23 2024 06:47:33 GMT+0000

        uint256 initialDayTimestamp_1 = 1716375609; // Wed May 22 2024 11:00:09 GMT+0000
        uint256 initialDayTimestamp_2 = 1716202809; // Mon May 20 2024 11:00:09 GMT+0000
        uint256 initialDayTimestamp_3 = 1714361889; // Mon Apr 29 2024 03:38:09 GMT+0000

        // initialDayTimestamp_1 -> finalDayTimestamp => 0.79 => Output: 0
        // initialDayTimestamp_2 -> finalDayTimestamp => 2.79 => Output: 2
        // initialDayTimestamp_3 -> finalDayTimestamp => 24.12 => Output: 24

        assertEq(
            reserveMathLibHarness.exposed__calculateDaysPassed(
                finalDayTimestamp,
                initialDayTimestamp_1
            ),
            0
        );
        assertEq(
            reserveMathLibHarness.exposed__calculateDaysPassed(
                finalDayTimestamp,
                initialDayTimestamp_2
            ),
            2
        );
        assertEq(
            reserveMathLibHarness.exposed__calculateDaysPassed(
                finalDayTimestamp,
                initialDayTimestamp_3
            ),
            24
        );
    }

    /// @dev Test the calculation of months passed
    function testReserveMathLib__calculateMonthsPassed() public view {
        uint256 finalMonthTimestamp = 1716446853; // Thu May 23 2024 06:47:33 GMT+0000

        uint256 initialMonthTimestamp_1 = 1716375609; // Wed May 22 2024 11:00:09 GMT+0000
        uint256 initialMonthTimestamp_2 = 1695958689; // Fri Sep 29 2023 03:38:09 GMT+0000
        uint256 initialMonthTimestamp_3 = 1680061089; // Wed Mar 29 2023 03:38:09 GMT+0000

        // initialMonthTimestamp_1 -> finalMonthTimestamp => 0.03 => Output: 0
        // initialMonthTimestamp_2 -> finalMonthTimestamp => 7.79 => Output: 7
        // initialMonthTimestamp_3 -> finalMonthTimestamp => 14.12 => Output: 14

        assertEq(
            reserveMathLibHarness.exposed__calculateMonthsPassed(
                finalMonthTimestamp,
                initialMonthTimestamp_1
            ),
            0
        );
        assertEq(
            reserveMathLibHarness.exposed__calculateMonthsPassed(
                finalMonthTimestamp,
                initialMonthTimestamp_2
            ),
            7
        );
        assertEq(
            reserveMathLibHarness.exposed__calculateMonthsPassed(
                finalMonthTimestamp,
                initialMonthTimestamp_3
            ),
            14
        );
    }
}
