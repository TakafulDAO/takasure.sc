// SPDX-License-Identifier: GNU GPLv3
/// @dev This contract is used to be able to test some internal functions

pragma solidity 0.8.28;

import {ReserveMathAlgorithms} from "contracts/helpers/libraries/algorithms/ReserveMathAlgorithms.sol";

contract ReserveMathAlgorithmsHarness {
    function exposed__updateProFormaFundReserve(
        uint256 currentProFormaFundReserve,
        uint256 memberNetContribution,
        uint256 currentDynamicReserveRatio
    ) external pure returns (uint256 exposedUpdatedProFormaFundReserve) {
        exposedUpdatedProFormaFundReserve = ReserveMathAlgorithms._updateProFormaFundReserve(
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
        exposedUpdatedProFormaClaimReserve = ReserveMathAlgorithms._updateProFormaClaimReserve(
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
        exposedUpdatedDynamicReserveRatio = ReserveMathAlgorithms._calculateDynamicReserveRatio(
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
        bma = ReserveMathAlgorithms._calculateBmaCashFlowMethod(
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
        exposedDaysPassed = ReserveMathAlgorithms._calculateDaysPassed(
            finalDayTimestamp,
            initialDayTimestamp
        );
    }

    function exposed__calculateMonthsPassed(
        uint256 finalMonthTimestamp,
        uint256 initialMonthTimestamp
    ) external pure returns (uint256 exposedMonthsPassed) {
        exposedMonthsPassed = ReserveMathAlgorithms._calculateMonthsPassed(
            finalMonthTimestamp,
            initialMonthTimestamp
        );
    }

    function exposed__maxUint(uint256 x, uint256 y) external pure returns (uint256 exposedMaxUint) {
        exposedMaxUint = ReserveMathAlgorithms._maxUint(x, y);
    }

    function exposed__maxInt(int256 x, int256 y) external pure returns (int256 exposedMaxInt) {
        exposedMaxInt = ReserveMathAlgorithms._maxInt(x, y);
    }

    function exposed__minUint(uint256 x, uint256 y) external pure returns (uint256 exposedMinUint) {
        exposedMinUint = ReserveMathAlgorithms._minUint(x, y);
    }

    function exposed__minInt(int256 x, int256 y) external pure returns (int256 exposedMinInt) {
        exposedMinInt = ReserveMathAlgorithms._minInt(x, y);
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
