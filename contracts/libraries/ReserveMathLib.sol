//SPDX-License-Identifier: GPL-3.0

/**
 * @title ReserveMathLib
 * @author Maikel Ordaz
 * @notice It includes the math functions to calculate reserve ratios and benefit multipliers
 */

pragma solidity 0.8.25;

import {Member} from "../types/TakasureTypes.sol";

library ReserveMathLib {
    error WrongTimestamps();

    /*//////////////////////////////////////////////////////////////
                           PRO FORMA RESERVES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The Fund Reserve based on each member’s fund reserve add, But taking out / removing
     *         any members that had claims or for any other reason aren't active anymore
     * @dev This value will lately be used to update the dynamic reserve ratio
     * @param _currentProFormaFundReserve Current value. Note: Six decimals
     * @param _memberContribution Net contribution of the member. Note: Six decimals
     * @param _initialReserveRatio Note: Percentage value, i.e. 40% => input should be 40
     * @return updatedProFormaFundReserve_ Updated value. Note: Six decimals
     */
    function _updateProFormaFundReserve(
        uint256 _currentProFormaFundReserve,
        uint256 _memberContribution,
        uint256 _initialReserveRatio
    ) internal pure returns (uint256 updatedProFormaFundReserve_) {
        updatedProFormaFundReserve_ =
            _currentProFormaFundReserve +
            ((_memberContribution * _initialReserveRatio) / 100);
    }

    /**
     * @notice Calculate the pro forma claim reserve, which should be updated on every cash-in operation
     * @param _currentProFormaClaimReserve Current value. Note: Six decimals
     * @param _memberContribution Net contribution of the member. Note: Six decimals
     * @param _serviceFee Service fee. Note: Percentage value, i.e. 20% => input should be 20
     * @param _initialReserveRatio Initial reserve ratio. Note: Percentage value, i.e. 40% => input should be 40
     * @return updatedProFormaClaimReserve_ Updated value. Note: Six decimals
     */
    function _updateProFormaClaimReserve(
        uint256 _currentProFormaClaimReserve,
        uint256 _memberContribution,
        uint8 _serviceFee,
        uint256 _initialReserveRatio
    ) internal pure returns (uint256 updatedProFormaClaimReserve_) {
        // updatedProFormaClaimReserve = currentProFormaClaimReserve + (memberContribution * (1 - serviceFee) * (1 - initialReserveRatio))
        // To avoid rounding issues as (1 - serviceFee) * (1 - initialReserveRatio) is always 1, in solidity. We use the percentage values and divide by 10^4
        updatedProFormaClaimReserve_ =
            _currentProFormaClaimReserve +
            ((_memberContribution * (100 - uint256(_serviceFee)) * (100 - _initialReserveRatio)) /
                10 ** 4);
    }

    /*//////////////////////////////////////////////////////////////
                                  DRR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate the dynamic reserve ratio on every cash-in operation
     * @param _proFormaFundReserve Pro forma fund reserve. Note: Six decimals
     * @param _fundReserve Fund reserve. Note: Six decimals
     * @param _cashFlowLastPeriod Cash flow of the last period of 12 months. Note: Six decimals
     * @return updatedDynamicReserveRatio_ Updated value. Note: Percentage value, i.e. 40% => return value will be 40
     * @dev The dynamic reserve ratio is calculated based on the current pro forma fund reserve
     */
    function _calculateDynamicReserveRatio(
        uint256 _initialReserveRatio,
        uint256 _proFormaFundReserve,
        uint256 _fundReserve,
        uint256 _cashFlowLastPeriod
    ) internal pure returns (uint256 updatedDynamicReserveRatio_) {
        int256 fundReserveShortfall = int256(_proFormaFundReserve) - int256(_fundReserve);

        if (fundReserveShortfall > 0 && _cashFlowLastPeriod > 0) {
            uint256 possibleDRR = _initialReserveRatio +
                ((uint256(fundReserveShortfall) * 100) / _cashFlowLastPeriod);

            if (possibleDRR < 100) {
                if (_initialReserveRatio < possibleDRR) updatedDynamicReserveRatio_ = possibleDRR;
                else updatedDynamicReserveRatio_ = _initialReserveRatio;
            } else {
                updatedDynamicReserveRatio_ = 100;
            }
        } else {
            updatedDynamicReserveRatio_ = _initialReserveRatio;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  BMA
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Helper function to calculate the benefit multiplier adjuster
     * @param _cashFlowLastPeriod Cash flow of the last period of 12 months. Note: Six decimals
     * @param _serviceFee Service fee. Note: Percentage value, i.e. 20% => input should be 20
     * @param _initialReserveRatio Initial dynamic reserve ratio. Note: Percentage value, i.e. 40% => input should be 40
     * @return bmaInflowAssumption_ Six decimals
     */
    // todo: this one can be inlined inside _calculateBmaCashFlowMethod, as it is only used there. It depends if we decide to use another bma method and it is used in other places
    function _calculateBmaInflowAssumption(
        uint256 _cashFlowLastPeriod,
        uint256 _serviceFee,
        uint256 _initialReserveRatio
    ) internal pure returns (uint256 bmaInflowAssumption_) {
        bmaInflowAssumption_ =
            (_cashFlowLastPeriod * (100 - _serviceFee) * (100 - _initialReserveRatio)) /
            10 ** 4;
    }

    /**
     * @notice Calculate the benefit multiplier adjuster through the Cash Flow Method
     * @param _totalClaimReserves Total claim reserves. Note: Six decimals
     * @param _totalFundReserves Total fund reserves. Note: Six decimals
     * @param _bmaFundReserveShares Percentage value, i.e. 70% => input should be 70
     * @param _proFormaClaimReserve Pro forma claim reserve. Note: Six decimals
     * @param _bmaInflowAssumption Six decimals
     * @return bma_ Percentage value, i.e. 100% => return value will be 100
     */
    function _calculateBmaCashFlowMethod(
        uint256 _totalClaimReserves,
        uint256 _totalFundReserves,
        uint256 _bmaFundReserveShares,
        uint256 _proFormaClaimReserve,
        uint256 _bmaInflowAssumption
    ) internal pure returns (uint256 bma_) {
        // Calculate BMA numerator
        uint256 bmaNumerator = _totalClaimReserves +
            _bmaInflowAssumption +
            ((_totalFundReserves * _bmaFundReserveShares) / 100);

        // Calculate BMA denominator
        uint256 bmaDenominator = (2 * _proFormaClaimReserve) +
            ((_totalFundReserves * _bmaFundReserveShares) / 100);

        if (bmaDenominator == 0) {
            bma_ = 100;
        } else {
            uint256 possibleBMA = (bmaNumerator * 100) / bmaDenominator;

            if (possibleBMA > 100) {
                bma_ = 100;
            } else {
                bma_ = possibleBMA;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              ECRes & UCRes
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate the earned and unearned contribution reserves for a member
    function _calculateEcrAndUcrByMember(Member storage member) internal returns (uint256, int256) {
        uint256 currentTimestamp = block.timestamp;
        uint256 claimReserveAdd = member.claimAddAmount;
        uint256 lastEcrTime = member.lastEcrTime;
        uint256 year = 365;
        uint256 decimalCorrection = 1e3;
        uint256 ecr;
        int256 ucr;

        if (lastEcrTime == 0) {
            // Time passed since the membership started
            uint256 membershipTerm = _calculateDaysPassed(
                currentTimestamp,
                member.membershipStartTime
            );

            ecr =
                ((((year - membershipTerm) * decimalCorrection) / year) * (claimReserveAdd)) /
                decimalCorrection;
        } else {
            // Time passed since last ECR calculation
            uint256 timeSinceLastCalc = _calculateDaysPassed(currentTimestamp, lastEcrTime);

            ecr =
                (((timeSinceLastCalc * decimalCorrection) / year) * (claimReserveAdd)) /
                decimalCorrection;
        }

        // Unearned contribution reserve
        ucr = int256(claimReserveAdd) - int256(ecr);

        member.lastEcrTime = currentTimestamp;
        member.lastEcr += ecr;
        member.lastUcr += ucr; // todo: not adding to previous

        return (member.lastEcr, member.lastUcr);
    }

    /*//////////////////////////////////////////////////////////////
                                 DATES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate date difference in days
     * @param _finalDayTimestamp Final timestamp
     * @param _initialDayTimestamp Initial timestamp
     * @return daysPassed_ Days passed
     */
    function _calculateDaysPassed(
        uint256 _finalDayTimestamp,
        uint256 _initialDayTimestamp
    ) internal pure returns (uint256 daysPassed_) {
        if (_finalDayTimestamp < _initialDayTimestamp) {
            revert WrongTimestamps();
        } else {
            uint256 dayTimePassed = _finalDayTimestamp - _initialDayTimestamp;
            if (dayTimePassed < 1 days) {
                daysPassed_ = 0;
            } else {
                daysPassed_ = dayTimePassed / 1 days;
            }
        }
    }

    /**
     * @notice Calculate date difference in months
     * @param _finalMonthTimestamp Final timestamp
     * @param _initialMonthTimestamp Initial timestamp
     * @return monthsPassed_ Months passed
     */
    function _calculateMonthsPassed(
        uint256 _finalMonthTimestamp,
        uint256 _initialMonthTimestamp
    ) internal pure returns (uint256 monthsPassed_) {
        if (_finalMonthTimestamp < _initialMonthTimestamp) {
            revert WrongTimestamps();
        } else {
            uint256 monthTimePassed = _finalMonthTimestamp - _initialMonthTimestamp;
            uint256 month = 30 days;
            if (monthTimePassed < month) {
                monthsPassed_ = 0;
            } else {
                monthsPassed_ = monthTimePassed / month;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                               UTILITIES
    //////////////////////////////////////////////////////////////*/

    function _maxUint(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assembly {
            z := xor(x, mul(xor(x, y), gt(y, x)))
        }
    }

    function _maxInt(int256 x, int256 y) internal pure returns (int256 z) {
        assembly {
            z := xor(x, mul(xor(x, y), sgt(y, x)))
        }
    }

    function _minUint(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assembly {
            z := xor(x, mul(xor(x, y), lt(y, x)))
        }
    }

    function _minInt(int256 x, int256 y) internal pure returns (int256 z) {
        assembly {
            z := xor(x, mul(xor(x, y), slt(y, x)))
        }
    }
}
