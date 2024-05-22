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
        uint256 proFormaFundReserve = 100;
        uint256 fundReserve = 50;
        uint256 cashFlowLastPeriod = 100;

        int256 fundReserveShortfall = int256(proFormaFundReserve) - int256(fundReserve);

        uint256 expectedDRR = currentDynamicReserveRatio +
            (uint256(fundReserveShortfall) / cashFlowLastPeriod);

        // drr = 40 + (50 / 100) = 40.5 < 100

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

        // drr = 96 + (50 / 10) = 101 > 100

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
}
