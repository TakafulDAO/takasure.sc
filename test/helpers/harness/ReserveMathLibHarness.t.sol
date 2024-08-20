// SPDX-License-Identifier: GPL-3.0
/// @dev This contract is used to be able to test some internal functions

pragma solidity 0.8.25;

import {ReserveMathLib} from "contracts/libraries/ReserveMathLib.sol";

contract ReserveMathLibHarness {
    function exposed__updateProFormaFundReserve(
        uint256 currentProFormaFundReserve,
        uint256 memberNetContribution,
        uint256 currentDynamicReserveRatio
    ) external pure returns (uint256 exposedUpdatedProFormaFundReserve) {
        exposedUpdatedProFormaFundReserve = ReserveMathLib._updateProFormaFundReserve(
            currentProFormaFundReserve,
            memberNetContribution,
            currentDynamicReserveRatio
        );
    }

    function exposed__updateProFormaClaimReserve(
        uint256 currentProFormaClaimReserve,
        uint256 memberNetContribution,
        uint8 serviceFee,
        uint256 initialReserveRatio
    ) external pure returns (uint256 exposedUpdatedProFormaClaimReserve) {
        exposedUpdatedProFormaClaimReserve = ReserveMathLib._updateProFormaClaimReserve(
            currentProFormaClaimReserve,
            memberNetContribution,
            serviceFee,
            initialReserveRatio
        );
    }

    function exposed__calculateDynamicReserveRatio(
        uint256 initialReserveRatio,
        uint256 proFormaFundReserve,
        uint256 fundReserve,
        uint256 cashFlowLastPeriod
    ) external pure returns (uint256 exposedUpdatedDynamicReserveRatio) {
        exposedUpdatedDynamicReserveRatio = ReserveMathLib._calculateDynamicReserveRatio(
            initialReserveRatio,
            proFormaFundReserve,
            fundReserve,
            cashFlowLastPeriod
        );
    }

    function exposed_calculateBmaCashFlowMethod(
        uint256 totalClaimReserves,
        uint256 totalFundReserves,
        uint256 bmaFundReserveShares,
        uint256 proFormaClaimReserve,
        uint256 bmaInflowAssumption
    ) external pure returns (uint256 bma) {
        bma = ReserveMathLib._calculateBmaCashFlowMethod(
            totalClaimReserves,
            totalFundReserves,
            bmaFundReserveShares,
            proFormaClaimReserve,
            bmaInflowAssumption
        );
    }

    function exposed__calculateDaysPassed(
        uint256 finalDayTimestamp,
        uint256 initialDayTimestamp
    ) external pure returns (uint256 exposedDaysPassed) {
        exposedDaysPassed = ReserveMathLib._calculateDaysPassed(
            finalDayTimestamp,
            initialDayTimestamp
        );
    }

    function exposed__calculateMonthsPassed(
        uint256 finalMonthTimestamp,
        uint256 initialMonthTimestamp
    ) external pure returns (uint256 exposedMonthsPassed) {
        exposedMonthsPassed = ReserveMathLib._calculateMonthsPassed(
            finalMonthTimestamp,
            initialMonthTimestamp
        );
    }

    function exposed__maxUint(uint256 x, uint256 y) external pure returns (uint256 exposedMaxUint) {
        exposedMaxUint = ReserveMathLib._maxUint(x, y);
    }

    function exposed__maxInt(int256 x, int256 y) external pure returns (int256 exposedMaxInt) {
        exposedMaxInt = ReserveMathLib._maxInt(x, y);
    }

    function exposed__minUint(uint256 x, uint256 y) external pure returns (uint256 exposedMinUint) {
        exposedMinUint = ReserveMathLib._minUint(x, y);
    }

    function exposed__minInt(int256 x, int256 y) external pure returns (int256 exposedMinInt) {
        exposedMinInt = ReserveMathLib._minInt(x, y);
    }
}
