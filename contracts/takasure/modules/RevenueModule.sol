//SPDX-License-Identifier: GPL-3.0

/**
 * @title RevenueModule
 * @author Maikel Ordaz
 * @dev Admins communicate with this module to deposit external revenues
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ModuleCheck} from "contracts/takasure/modules/moduleUtils/ModuleCheck.sol";

import {Reserve, RevenueType, CashFlowVars} from "contracts/types/TakasureTypes.sol";
import {ModuleConstants} from "contracts/libraries/ModuleConstants.sol";
import {ReserveMathLib} from "contracts/libraries/ReserveMathLib.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract RevenueModule is Initializable, UUPSUpgradeable, AccessControlUpgradeable, ModuleCheck {
    using SafeERC20 for IERC20;

    ITakasureReserve private takasureReserve;

    Reserve private reserve;

    error RevenueModule__WrongRevenueType();

    function initialize(address _takasureReserveAddress) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();

        takasureReserve = ITakasureReserve(_takasureReserveAddress);
        address takadaoOperator = takasureReserve.takadaoOperator();
        address daoMultisig = takasureReserve.daoMultisig();

        _grantRole(DEFAULT_ADMIN_ROLE, takadaoOperator);
        _grantRole(ModuleConstants.TAKADAO_OPERATOR, takadaoOperator);
        _grantRole(ModuleConstants.DAO_MULTISIG, daoMultisig);
    }

    /**
     * @notice To be called by the DAO to update the Fund reserve with new revenues
     * @param newRevenue the new revenue to be added to the fund reserve
     * @param revenueType the type of revenue to be added
     */
    function depositRevenue(
        uint256 newRevenue,
        RevenueType revenueType
    ) external onlyRole(ModuleConstants.DAO_MULTISIG) {
        require(revenueType != RevenueType.Contribution, RevenueModule__WrongRevenueType());

        Reserve memory reserveValues = takasureReserve.getReserveValues();

        reserve.totalFundRevenues += newRevenue;
        _updateCashMappings(newRevenue);
        reserve.totalFundReserve += newRevenue;

        address contributionToken = reserve.contributionToken;

        IERC20(contributionToken).safeTransferFrom(msg.sender, address(this), newRevenue);

        takasureReserve.setReserveValuesFromModule(reserveValues);

        emit TakasureEvents.OnExternalRevenue(newRevenue, reserve.totalFundReserve, revenueType);
    }

    function _updateCashMappings(uint256 _cashIn) internal {
        CashFlowVars memory cashFlowVars = takasureReserve.getCashFlowValues();

        uint256 currentTimestamp = block.timestamp;
        uint256 prevCashIn;

        if (cashFlowVars.dayDepositTimestamp == 0 && cashFlowVars.monthDepositTimestamp == 0) {
            // If the depositTimestamp is 0 it means it is the first deposit
            // Set the initial values for future calculations and reference
            cashFlowVars.dayDepositTimestamp = currentTimestamp;
            cashFlowVars.monthDepositTimestamp = currentTimestamp;
            takasureReserve.setMonthToCashFlowValuesFromModule(
                cashFlowVars.monthReference,
                _cashIn
            );
            takasureReserve.setDayToCashFlowValuesFromModule(
                cashFlowVars.monthReference,
                cashFlowVars.dayReference,
                _cashIn
            );
        } else {
            // Check how many days and months have passed since the last deposit
            uint256 daysPassed = ReserveMathLib._calculateDaysPassed(
                currentTimestamp,
                cashFlowVars.dayDepositTimestamp
            );
            uint256 monthsPassed = ReserveMathLib._calculateMonthsPassed(
                currentTimestamp,
                cashFlowVars.monthDepositTimestamp
            );

            if (monthsPassed == 0) {
                // If no months have passed, update the mapping for the current month
                prevCashIn = takasureReserve.monthToCashFlow(cashFlowVars.monthReference);
                takasureReserve.setMonthToCashFlowValuesFromModule(
                    cashFlowVars.monthReference,
                    prevCashIn + _cashIn
                );
                if (daysPassed == 0) {
                    // If no days have passed, update the mapping for the current day
                    prevCashIn = takasureReserve.dayToCashFlow(
                        cashFlowVars.monthReference,
                        cashFlowVars.dayReference
                    );
                    takasureReserve.setDayToCashFlowValuesFromModule(
                        cashFlowVars.monthReference,
                        cashFlowVars.dayReference,
                        prevCashIn + _cashIn
                    );
                } else {
                    // If it is a new day, update the day deposit timestamp and the new day reference
                    cashFlowVars.dayDepositTimestamp += daysPassed * ModuleConstants.DAY;
                    cashFlowVars.dayReference += uint8(daysPassed);

                    // Update the mapping for the new day
                    takasureReserve.setDayToCashFlowValuesFromModule(
                        cashFlowVars.monthReference,
                        cashFlowVars.dayReference,
                        _cashIn
                    );
                }
            } else {
                // If it is a new month, update the month deposit timestamp and the day deposit timestamp
                // both should be the same as it is a new month
                cashFlowVars.monthDepositTimestamp += monthsPassed * ModuleConstants.MONTH;
                cashFlowVars.dayDepositTimestamp = cashFlowVars.monthDepositTimestamp;
                // Update the month reference to the corresponding month
                cashFlowVars.monthReference += uint16(monthsPassed);
                // Calculate the day reference for the new month, we need to recalculate the days passed
                // with the new day deposit timestamp
                daysPassed = ReserveMathLib._calculateDaysPassed(
                    currentTimestamp,
                    cashFlowVars.dayDepositTimestamp
                );
                // The new day reference is the days passed + initial day. Initial day refers
                // to the first day of the month
                uint8 initialDay = 1;
                cashFlowVars.dayReference = uint8(daysPassed) + initialDay;

                // Update the mappings for the new month and day
                takasureReserve.setMonthToCashFlowValuesFromModule(
                    cashFlowVars.monthReference,
                    _cashIn
                );
                takasureReserve.setDayToCashFlowValuesFromModule(
                    cashFlowVars.monthReference,
                    cashFlowVars.dayReference,
                    _cashIn
                );
            }
        }

        takasureReserve.setCashFlowValuesFromModule(cashFlowVars);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(ModuleConstants.TAKADAO_OPERATOR) {}
}
