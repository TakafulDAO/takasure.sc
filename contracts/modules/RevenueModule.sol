//SPDX-License-Identifier: GPL-3.0

/**
 * @title RevenueModule
 * @author Maikel Ordaz
 * @dev Admins communicate with this module to deposit external revenues
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {IAddressManager} from "contracts/interfaces/IAddressManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";

import {Reserve, RevenueType, CashFlowVars, ModuleState} from "contracts/types/TakasureTypes.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ReserveMathAlgorithms} from "contracts/helpers/libraries/algorithms/ReserveMathAlgorithms.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";

pragma solidity 0.8.28;

contract RevenueModule is Initializable, UUPSUpgradeable, TLDModuleImplementation {
    using SafeERC20 for IERC20;

    ITakasureReserve private takasureReserve;

    error RevenueModule__WrongRevenueType();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _takasureReserveAddress) external initializer {
        AddressAndStates._notZeroAddress(_takasureReserveAddress);
        __UUPSUpgradeable_init();

        takasureReserve = ITakasureReserve(_takasureReserveAddress);
    }

    /**
     * @notice To be called by the DAO to update the Fund reserve with new revenues
     * @param newRevenue the new revenue to be added to the fund reserve
     * @param revenueType the type of revenue to be added
     */
    function depositRevenue(
        uint256 newRevenue,
        RevenueType revenueType
    ) external onlyRole(Roles.DAO_MULTISIG, address(takasureReserve.addressManager())) {
        AddressAndStates._onlyModuleState(
            IAddressManager(addressManager).getProtocolAddressByName("MODULE_MANAGER").addr,
            address(this),
            ModuleState.Enabled
        );
        require(revenueType != RevenueType.Contribution, RevenueModule__WrongRevenueType());

        Reserve memory reserve = takasureReserve.getReserveValues();

        reserve.totalFundRevenues += newRevenue;
        _updateCashMappings(newRevenue);
        reserve.totalFundReserve += newRevenue;

        address contributionToken = reserve.contributionToken;

        IERC20(contributionToken).safeTransferFrom(
            msg.sender,
            address(takasureReserve),
            newRevenue
        );

        takasureReserve.setReserveValuesFromModule(reserve);

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
            uint256 daysPassed = ReserveMathAlgorithms._calculateDaysPassed(
                currentTimestamp,
                cashFlowVars.dayDepositTimestamp
            );
            uint256 monthsPassed = ReserveMathAlgorithms._calculateMonthsPassed(
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
                daysPassed = ReserveMathAlgorithms._calculateDaysPassed(
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
    ) internal override onlyRole(Roles.OPERATOR, address(takasureReserve.addressManager())) {}
}
