// SPDX-License-Identifier: GPL-3.0
/// @dev This contract is used to be able to test some internal functions

pragma solidity 0.8.25;

import {ReserveMathLib} from "../../../../contracts/libraries/ReserveMathLib.sol";

contract ReserveMathLibHarness {
    function exposed__updateProFormas(
        uint256 currentProFormaFundReserve,
        uint256 currentProFormaClaimReserve,
        uint256 memberNetContribution,
        uint256 initialReserveRatio,
        uint256 currentDynamicReserveRatio,
        uint8 wakalaFee
    )
        external
        pure
        returns (
            uint256 exposedUpdatedProFormaFundReserve,
            uint256 exposedUpdatedProFormaClaimReserve
        )
    {
        (exposedUpdatedProFormaFundReserve, exposedUpdatedProFormaClaimReserve) = ReserveMathLib
            ._updateProFormas(
                currentProFormaFundReserve,
                currentProFormaClaimReserve,
                memberNetContribution,
                initialReserveRatio,
                currentDynamicReserveRatio,
                wakalaFee
            );
    }

    function exposed__calculateDynamicReserveRatioReserveShortfallMethod(
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
}
