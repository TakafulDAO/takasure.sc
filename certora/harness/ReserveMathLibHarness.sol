// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {ReserveMathLib} from "../munged/libraries/ReserveMathLib.sol";

contract ReserveMathLibHarness {
    function updateProFormaFundReserve(
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

    function updateProFormaClaimReserve(
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

    function calculateDynamicReserveRatioReserveShortfallMethod(
        uint256 currentDynamicReserveRatio,
        uint256 proFormaFundReserve,
        uint256 fundReserve,
        uint256 cashFlowLastPeriod
    ) external pure returns (uint256 exposedUpdatedDynamicReserveRatio) {
        exposedUpdatedDynamicReserveRatio = ReserveMathLib
            ._calculateDynamicReserveRatioReserveShortfallMethod(
                currentDynamicReserveRatio,
                proFormaFundReserve,
                fundReserve,
                cashFlowLastPeriod
            );
    }

    function calculateBmaInflowAssumption(
        uint256 cashFlowLastPeriod,
        uint256 serviceFee,
        uint256 initialDRR
    ) external pure returns (uint256 exposedBmaInflowAssumption) {
        exposedBmaInflowAssumption = ReserveMathLib._calculateBmaInflowAssumption(
            cashFlowLastPeriod,
            serviceFee,
            initialDRR
        );
    }

    function calculateBmaCashFlowMethodNumerator(
        uint256 totalClaimReserves,
        uint256 totalFundReserves,
        uint256 bmaFundReserveShares,
        uint256 bmaInflowAssumption
    ) external pure returns (uint256 exposedBmaNumerator) {
        exposedBmaNumerator = ReserveMathLib._calculateBmaCashFlowMethodNumerator(
            totalClaimReserves,
            totalFundReserves,
            bmaFundReserveShares,
            bmaInflowAssumption
        );
    }

    function calculateBmaCashFlowMethodDenominator(
        uint256 totalFundReserves,
        uint256 bmaFundReserveShares,
        uint256 proFormaClaimReserve
    ) external pure returns (uint256 exposedBmaDenominator) {
        exposedBmaDenominator = ReserveMathLib._calculateBmaCashFlowMethodDenominator(
            totalFundReserves,
            bmaFundReserveShares,
            proFormaClaimReserve
        );
    }

    function calculateBmaCashFlowMethod(
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

    function calculateDaysPassed(
        uint256 finalDayTimestamp,
        uint256 initialDayTimestamp
    ) external pure returns (uint256 exposedDaysPassed) {
        exposedDaysPassed = ReserveMathLib._calculateDaysPassed(
            finalDayTimestamp,
            initialDayTimestamp
        );
    }

    function calculateMonthsPassed(
        uint256 finalMonthTimestamp,
        uint256 initialMonthTimestamp
    ) external pure returns (uint256 exposedMonthsPassed) {
        exposedMonthsPassed = ReserveMathLib._calculateMonthsPassed(
            finalMonthTimestamp,
            initialMonthTimestamp
        );
    }
}
