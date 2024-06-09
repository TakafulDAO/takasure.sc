//SPDX-License-Identifier: GPL-3.0

/**
 * @title ReserveMathLib
 * @author Maikel Ordaz
 * @notice It includes the math functions to calculate reserve ratios and benefit multipliers
 */

pragma solidity 0.8.25;

library ReserveMathLib {
    error WrongTimestamps();

    /*//////////////////////////////////////////////////////////////
                               PRO FORMA
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The Fund Reserve based on each member’s fund reserve add, But taking out / removing
     *         any members that had claims or for any other reason aren't active anymore
     * @dev This value will lately be used to update the dynamic reserve ratio
     * @param _currentProFormaFundReserve Current value. Note: Six decimals
     * @param _memberContribution Net contribution of the member. Note: Six decimals
     * @param _currentDynamicReserveRatio Current dynamic reserve ratio. Note: Percentage value,
     *                                    i.e. 40% => input should be 40
     * @return updatedProFormaFundReserve_ Updated value. Note: Six decimals
     */
    function _updateProFormaFundReserve(
        uint256 _currentProFormaFundReserve,
        uint256 _memberContribution,
        uint256 _currentDynamicReserveRatio
    ) internal pure returns (uint256 updatedProFormaFundReserve_) {
        updatedProFormaFundReserve_ =
            _currentProFormaFundReserve +
            ((_memberContribution * _currentDynamicReserveRatio) / 100);
    }

    /**
     * @notice Calculate the pro forma claim reserve, which should be updated on every cash-in operation
     * @param _currentProFormaClaimReserve Current value. Note: Six decimals
     * @param _memberContribution Net contribution of the member. Note: Six decimals
     * @param _wakalaFee Wakala fee. Note: Percentage value, i.e. 20% => input should be 20
     * @param _initialReserveRatio Initial reserve ratio. Note: Percentage value, i.e. 40% => input should be 40
     * @return updatedProFormaClaimReserve_ Updated value. Note: Six decimals
     */
    function _updateProFormaClaimReserve(
        uint256 _currentProFormaClaimReserve,
        uint256 _memberContribution,
        uint8 _wakalaFee,
        uint256 _initialReserveRatio
    ) internal pure returns (uint256 updatedProFormaClaimReserve_) {
        // updatedProFormaClaimReserve = currentProFormaClaimReserve + (memberContribution * (1 - wakalaFee) * (1 - initialReserveRatio))
        // To avoid rounding issues as (1 - wakalaFee) * (1 - initialReserveRatio) is always 1, in solidity. We use the percentage values and divide by 10^4
        updatedProFormaClaimReserve_ =
            _currentProFormaClaimReserve +
            ((_memberContribution * (100 - uint256(_wakalaFee)) * (100 - _initialReserveRatio)) /
                10 ** 4);
    }

    /*//////////////////////////////////////////////////////////////
                                  DRR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate the dynamic reserve ratio on every cash-in operation
     * @param _currentDynamicReserveRatio Current value. Note: Percentage value, i.e. 40% => input should be 40
     * @param _proFormaFundReserve Pro forma fund reserve. Note: Six decimals
     * @param _fundReserve Fund reserve. Note: Six decimals
     * @param _cashFlowLastPeriod Cash flow of the last period of 12 months. Note: Six decimals
     * @return updatedDynamicReserveRatio_ Updated value. Note: Percentage value, i.e. 40% => return value will be 40
     * @dev The dynamic reserve ratio is calculated based on the current pro forma fund reserve
     */
    function _calculateDynamicReserveRatioReserveShortfallMethod(
        uint256 _currentDynamicReserveRatio,
        uint256 _proFormaFundReserve,
        uint256 _fundReserve,
        uint256 _cashFlowLastPeriod
    ) internal pure returns (uint256 updatedDynamicReserveRatio_) {
        int256 fundReserveShortfall = int256(_proFormaFundReserve) - int256(_fundReserve);

        if (fundReserveShortfall > 0 && _cashFlowLastPeriod > 0) {
            uint256 possibleDRR = _currentDynamicReserveRatio +
                ((uint256(fundReserveShortfall) * 100) / _cashFlowLastPeriod);

            if (possibleDRR < 100) {
                updatedDynamicReserveRatio_ = possibleDRR;
            } else {
                updatedDynamicReserveRatio_ = 100;
            }
        } else {
            updatedDynamicReserveRatio_ = _currentDynamicReserveRatio;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  BMA
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Helper function to calculate the benefit multiplier adjuster
     * @param _cashFlowLastPeriod Cash flow of the last period of 12 months. Note: Six decimals
     * @param _wakalaFee Wakala fee. Note: Percentage value, i.e. 20% => input should be 20
     * @param _initialDRR Initial dynamic reserve ratio. Note: Percentage value, i.e. 40% => input should be 40
     * @return bmaInflowAssumption_ Six decimals
     */
    function _bmaLastPeriodInflowAssumption(
        uint256 _cashFlowLastPeriod,
        uint256 _wakalaFee,
        uint256 _initialDRR
    ) internal pure returns (uint256 bmaInflowAssumption_) {
        bmaInflowAssumption_ =
            (_cashFlowLastPeriod * (100 - _wakalaFee) * (100 - _initialDRR)) /
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
    ) internal pure returns (uint256 bma_) {}

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
}
