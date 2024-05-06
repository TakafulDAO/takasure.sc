//SPDX-License-Identifier: GPL-3.0

/**
 * @title ReserveMathLib
 * @author Maikel Ordaz
 * @notice It includes the math functions to calculate reserve ratios and benefir multipliers
 */

pragma solidity 0.8.25;

library ReserveMathLib {
    /**
     * @notice The Fund Reserve based on each member’s fund reserve add, But taking out / removing
     *         any members that had claims or for any other reason aren't active anymore
     * @dev This value will lately be used to update the dynamic reserve ratio
     * @param _currentProFormaFundReserve Current value
     * @param _memberNetContribution Net contribution of the member
     * @param _currentDynamicReserveRatio Current dynamic reserve ratio
     * @return _updatedProFormaFundReserve Updated value
     */
    function _updateProFormaFundReserve(
        uint256 _currentProFormaFundReserve,
        uint256 _memberNetContribution,
        uint256 _currentDynamicReserveRatio
    ) internal view returns (uint256 _updatedProFormaFundReserve) {
        _updatedProFormaFundReserve =
            _currentProFormaFundReserve +
            (_memberNetContribution * _currentDynamicReserveRatio);
    }
}
