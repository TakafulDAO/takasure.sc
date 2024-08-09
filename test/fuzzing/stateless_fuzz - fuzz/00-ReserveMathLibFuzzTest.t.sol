// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {ReserveMathLibHarness} from "../../helpers/harness/ReserveMathLibHarness.t.sol";

contract ReserveMathLibFuzzTest is Test {
    ReserveMathLibHarness public reserveMathLibHarness;

    function setUp() public {
        reserveMathLibHarness = new ReserveMathLibHarness();
    }

    /*//////////////////////////////////////////////////////////////
                            DYNAMIC RESERVE
    //////////////////////////////////////////////////////////////*/

    /// @dev The DRR should be updated if the fund reserve is less than the pro forma fund reserve and the possible DRR is less than 100
    function test_fuzz_calculateDynamicReserveRatioReserve(
        uint256 proFormaFundReserve,
        uint256 fundReserve,
        uint256 cashFlowLastPeriod
    ) public view {
        uint256 initialReserveRatio = 40;
        uint256 expectedDRR;
        // The next three bounds are arbitrary, but they should be in the same range as the other
        // values and should not be 0. Only to avoid weird random values in the fuzzing
        proFormaFundReserve = bound(proFormaFundReserve, 1, 1000);
        fundReserve = bound(fundReserve, 1, 1000);
        cashFlowLastPeriod = bound(cashFlowLastPeriod, 1, 1000);

        int256 fundReserveShortfall = int256(proFormaFundReserve) - int256(fundReserve);

        if (fundReserveShortfall <= 0) {
            expectedDRR = initialReserveRatio;
        } else {
            // possibleDRR = _currentDynamicReserveRatio + (uint256(_fundReserveShortfall * 100) / _cashFlowLastPeriod);
            uint256 possibleDRR = initialReserveRatio +
                ((uint256(fundReserveShortfall) * 100) / cashFlowLastPeriod);

            if (possibleDRR < 100) {
                if (initialReserveRatio < possibleDRR) expectedDRR = possibleDRR;
                else expectedDRR = initialReserveRatio;
            } else {
                expectedDRR = 100;
            }
        }

        uint256 updatedDynamicReserveRatio = reserveMathLibHarness
            .exposed__calculateDynamicReserveRatio(
                initialReserveRatio,
                proFormaFundReserve,
                fundReserve,
                cashFlowLastPeriod
            );

        assertEq(updatedDynamicReserveRatio, expectedDRR, "DRR should be updated correctly");
    }
}
