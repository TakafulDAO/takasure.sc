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

    function testReserveMathLib__updateProFormaFundReserve() public view {
        uint256 currentProFormaFundReserve = 100;
        uint256 memberNetContribution = 50;
        uint256 currentDynamicReserveRatio = 50;

        uint256 updatedProFormaFundReserve = reserveMathLibHarness
            .exposed__updateProFormaFundReserve(
                currentProFormaFundReserve,
                memberNetContribution,
                currentDynamicReserveRatio
            );

        assertEq(updatedProFormaFundReserve, 125);
    }

    /*//////////////////////////////////////////////////////////////
                 DYNAMIC RESERVE RATIO SHORTFALL METHOD
    //////////////////////////////////////////////////////////////*/

    /// @dev The DRR should remain the same if the fund reserve is greater than the pro forma fund reserve
    function testReserveMathLib__calculateDynamicReserveRatioReserveShortfallMethod_noShortfall()
        public
        view
    {
        uint256 currentDynamicReserveRatio = 50;
        uint256 proFormaFundReserve = 100;
        uint256 fundReserve = 200;
        uint256 cashFlowLastPeriod = 100;

        // proFormaFundReserve - fundReserve = 100 - 200 = -100 < 0 => drr remains the same

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
        uint256 proFormaFundReserve = 1000;
        uint256 fundReserve = 500;
        uint256 cashFlowLastPeriod = 100;

        // fundReserveShortfall = proFormaFundReserve - fundReserve;
        // fundReserveShortfall = 1000 - 500 = 500

        // expectedDRR = currentDynamicReserveRatio + (fundReserveShortfall / cashFlowLastPeriod);
        // expectedDRR = 40 + (500 / 100) = 45 < 100 => Update DRR = 45

        uint256 expectedDRR = 45;

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
        uint256 currentDynamicReserveRatio = 96;
        uint256 proFormaFundReserve = 100;
        uint256 fundReserve = 50;
        uint256 cashFlowLastPeriod = 10;

        // fundReserveShortfall = proFormaFundReserve - fundReserve;
        // fundReserveShortfall = 100 - 50 = 50

        // expectedDRR = currentDynamicReserveRatio + (fundReserveShortfall / cashFlowLastPeriod);
        // expectedDRR = 96 + (50 / 10) = 101 > 100 => Updated DRR = 100

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
