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
        uint256 currentDynamicReserveRatio = 40;
        uint256 proFormaFundReserve = 100000000;
        uint256 fundReserve = 25000000;
        uint256 cashFlowLastPeriod = 25000000;

        // fundReserveShortfall = proFormaFundReserve - fundReserve;
        // fundReserveShortfall = 100_000_000 - 25_000_000 = 75_000_000 > 0
        // cashFlowLastPeriod = 25_000_000 > 0

        // possibleDRR = currentDynamicReserveRatio + (fundReserveShortfall / cashFlowLastPeriod);
        // possibleDRR = 40 + (75_000_000 / 25_000_000) = 43 < 100 => Updated DRR = 43
        // expectedDRR = 43

        uint256 expectedDRR = 43;

        uint256 updatedDynamicReserveRatio = reserveMathLibHarness
            .exposed__calculateDynamicReserveRatioReserveShortfallMethod(
                currentDynamicReserveRatio,
                proFormaFundReserve,
                fundReserve,
                cashFlowLastPeriod
            );

        assertEq(updatedDynamicReserveRatio, expectedDRR);
    }

    /// @dev The DRR should be updated if the fund reserve is less than the pro forma fund reserve and the possible DRR is greater than 100
    function testReserveMathLib__calculateDynamicReserveRatioReserveShortfallMethod_shortfallGreaterThan100()
        public
        view
    {
        uint256 currentDynamicReserveRatio = 98;
        uint256 proFormaFundReserve = 100000000;
        uint256 fundReserve = 25000000;
        uint256 cashFlowLastPeriod = 25000000;

        // fundReserveShortfall = proFormaFundReserve - fundReserve;
        // fundReserveShortfall = 100_000_000 - 25_000_000 = 75_000_000 > 0
        // cashFlowLastPeriod = 25_000_000 > 0

        // possibleDRR = currentDynamicReserveRatio + (fundReserveShortfall / cashFlowLastPeriod);
        // possibleDRR = 98 + (75_000_000 / 25000000) = 101 > 100 => Updated DRR = 100
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
