// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {ReserveMathLibHarness} from "../helpers/harness/ReserveMathLibHarness.t.sol";

contract ReserveMathLibFuzzTest is Test {
    ReserveMathLibHarness public reserveMathLibHarness;

    function setUp() public {
        reserveMathLibHarness = new ReserveMathLibHarness();
    }

    /*//////////////////////////////////////////////////////////////
                 DYNAMIC RESERVE RATIO SHORTFALL METHOD
    //////////////////////////////////////////////////////////////*/

    /// @dev The DRR should be updated if the fund reserve is less than the pro forma fund reserve and the possible DRR is less than 100
    function test_fuzz_calculateDynamicReserveRatioReserve(
        uint256 currentDynamicReserveRatio,
        uint256 proFormaFundReserve,
        uint256 fundReserve,
        uint256 cashFlowLastPeriod
    ) public view {
        uint256 expectedDRR;
        currentDynamicReserveRatio = bound(currentDynamicReserveRatio, 1, 100);
        proFormaFundReserve = bound(proFormaFundReserve, 1, 1000);
        fundReserve = bound(fundReserve, 1, 1000);
        cashFlowLastPeriod = bound(cashFlowLastPeriod, 1, 1000);

        int256 fundReserveShortfall = int256(proFormaFundReserve) - int256(fundReserve);

        if (fundReserveShortfall <= 0) {
            expectedDRR = currentDynamicReserveRatio;
        } else {
            // possibleDRR = _currentDynamicReserveRatio + (uint256(_fundReserveShortfall * 100) / _cashFlowLastPeriod);
            uint256 possibleDRR = currentDynamicReserveRatio +
                (uint256(fundReserveShortfall) / cashFlowLastPeriod);

            if (possibleDRR < 100) {
                expectedDRR = possibleDRR;
            } else {
                expectedDRR = 100;
            }
        }

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
