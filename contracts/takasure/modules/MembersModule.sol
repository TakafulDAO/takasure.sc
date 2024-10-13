//SPDX-License-Identifier: GPL-3.0

/**
 * @title MembersModule
 * @author Maikel Ordaz
 * @notice This contract will manage defaults, cancelations and recurring payments
 * @dev It will interact with the TakasureReserve contract to update the values
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBenefitMultiplierConsumer} from "contracts/interfaces/IBenefitMultiplierConsumer.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {ITSToken} from "contracts/interfaces/ITSToken.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {Reserve, Member, MemberState, RevenueType, CashFlowVars} from "contracts/types/TakasureTypes.sol";
import {ReserveMathLib} from "contracts/libraries/ReserveMathLib.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {TakasureErrors} from "contracts/libraries/TakasureErrors.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract MembersModule is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransientUpgradeable
{
    using SafeERC20 for IERC20;

    ITakasureReserve private takasureReserve;
    IBenefitMultiplierConsumer private bmConsumer;

    bytes32 public constant TAKADAO_OPERATOR = keccak256("TAKADAO_OPERATOR");

    uint256 private constant DECIMALS_PRECISION = 1e12;
    uint256 private constant MONTH = 30 days; // Todo: manage a better way for 365 days and leap years maybe?
    uint256 private constant DAY = 1 days;

    uint256 private transient mintedTokens;

    modifier notZeroAddress(address _address) {
        require(_address != address(0), TakasureErrors.TakasureProtocol__ZeroAddress());
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _takasureReserveAddress
    ) external initializer notZeroAddress(_takasureReserveAddress) {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuardTransient_init();

        takasureReserve = ITakasureReserve(_takasureReserveAddress);
        bmConsumer = IBenefitMultiplierConsumer(takasureReserve.bmConsumer());
        address takadaoOperator = takasureReserve.takadaoOperator();

        _grantRole(DEFAULT_ADMIN_ROLE, takadaoOperator);
        _grantRole(TAKADAO_OPERATOR, takadaoOperator);
    }

    function recurringPayment() external nonReentrant {
        (Reserve memory reserve, Member memory newMember) = _getReserveAndMemberValuesHook(
            msg.sender
        );

        require(
            newMember.memberState == MemberState.Active,
            TakasureErrors.Module__WrongMemberState()
        );

        uint256 currentTimestamp = block.timestamp;
        uint256 membershipStartTime = newMember.membershipStartTime;
        uint256 membershipDuration = newMember.membershipDuration;
        uint256 lastPaidYearStartDate = newMember.lastPaidYearStartDate;
        uint256 year = 365 days;
        uint256 gracePeriod = 30 days;

        require(
            currentTimestamp <= lastPaidYearStartDate + year + gracePeriod &&
                currentTimestamp <= membershipStartTime + membershipDuration,
            TakasureErrors.MembersModule__InvalidDate()
        );

        uint256 contributionBeforeFee = newMember.contribution;
        uint256 feeAmount = (contributionBeforeFee * reserve.serviceFee) / 100;
        uint256 contributionAfterFee = contributionBeforeFee - feeAmount;

        // Update the values
        newMember.lastPaidYearStartDate += 365 days;
        newMember.totalContributions += contributionBeforeFee;
        newMember.totalServiceFee += feeAmount;
        newMember.lastEcr = 0;
        newMember.lastUcr = 0;

        // And we pay the contribution
        reserve = _memberPaymentFlow({
            _contributionBeforeFee: contributionBeforeFee,
            _contributionAfterFee: contributionAfterFee,
            _memberWallet: msg.sender,
            _reserve: reserve
        });

        newMember.creditTokensBalance += mintedTokens;

        emit TakasureEvents.OnRecurringPayment(
            msg.sender,
            newMember.memberId,
            newMember.lastPaidYearStartDate,
            newMember.totalContributions,
            newMember.totalServiceFee
        );

        _setNewReserveAndMemberValuesHook(reserve, newMember);
        takasureReserve.memberSurplus(newMember);
    }

    function _getReserveAndMemberValuesHook(
        address _memberWallet
    ) internal view returns (Reserve memory reserve_, Member memory member_) {
        reserve_ = takasureReserve.getReserveValues();
        member_ = takasureReserve.getMemberFromAddress(_memberWallet);
    }

    function _setNewReserveAndMemberValuesHook(
        Reserve memory _reserve,
        Member memory _newMember
    ) internal {
        takasureReserve.setReserveValuesFromModule(_reserve);
        takasureReserve.setMemberValuesFromModule(_newMember);
    }

    /**
     * @notice This function will update all the variables needed when a member pays the contribution
     */
    function _memberPaymentFlow(
        uint256 _contributionBeforeFee,
        uint256 _contributionAfterFee,
        address _memberWallet,
        Reserve memory _reserve
    ) internal returns (Reserve memory) {
        _reserve = _updateNewReserveValues(_contributionAfterFee, _contributionBeforeFee, _reserve);

         IERC20(_reserve.contributionToken).safeTransferFrom(
            _memberWallet,
            address(takasureReserve),
            _contributionAfterFee
        );

        // Mint the DAO Tokens
        _mintDaoTokens(_contributionBeforeFee);

        return _reserve;
    }

    function _updateNewReserveValues(
        uint256 _contributionAfterFee,
        uint256 _contributionBeforeFee,
        Reserve memory _reserve
    ) internal returns (Reserve memory) {
        (
            uint256 updatedProFormaFundReserve,
            uint256 updatedProFormaClaimReserve
        ) = _updateProFormas(_contributionAfterFee, _contributionBeforeFee, _reserve);
        _reserve.proFormaFundReserve = updatedProFormaFundReserve;
        _reserve.proFormaClaimReserve = updatedProFormaClaimReserve;

        (
            uint256 toFundReserve,
            uint256 toClaimReserve,
            uint256 marketExpenditure
        ) = _updateReserveBalaces(_contributionAfterFee, _reserve);

        _reserve.totalFundReserve += toFundReserve;
        _reserve.totalClaimReserve += toClaimReserve;
        _reserve.totalContributions += _contributionBeforeFee;
        _reserve.totalFundCost += marketExpenditure;
        _reserve.totalFundRevenues += _contributionAfterFee;

        _updateCashMappings(_contributionAfterFee);
        uint256 cashLast12Months = _cashLast12Months();

        uint256 updatedDynamicReserveRatio = _updateDRR(cashLast12Months, _reserve);
        _reserve.dynamicReserveRatio = updatedDynamicReserveRatio;

        uint256 updatedBMA = _updateBMA(cashLast12Months, _reserve);
        _reserve.benefitMultiplierAdjuster = updatedBMA;

        uint256 lossRatio = _updateLossRatio(_reserve.totalFundCost, _reserve.totalFundRevenues);
        _reserve.lossRatio = lossRatio;

        return _reserve;
    }

    function _updateProFormas(
        uint256 _contributionAfterFee,
        uint256 _contributionBeforeFee,
        Reserve memory _reserve
    ) internal returns (uint256 updatedProFormaFundReserve_, uint256 updatedProFormaClaimReserve_) {
        updatedProFormaFundReserve_ = ReserveMathLib._updateProFormaFundReserve(
            _reserve.proFormaFundReserve,
            _contributionAfterFee,
            _reserve.initialReserveRatio
        );

        updatedProFormaClaimReserve_ = ReserveMathLib._updateProFormaClaimReserve(
            _reserve.proFormaClaimReserve,
            _contributionBeforeFee,
            _reserve.serviceFee,
            _reserve.initialReserveRatio
        );

        emit TakasureEvents.OnNewProFormaValues(
            updatedProFormaFundReserve_,
            updatedProFormaClaimReserve_
        );
    }

    function _updateReserveBalaces(
        uint256 _contributionAfterFee,
        Reserve memory _reserve
    )
        internal
        returns (uint256 toFundReserve_, uint256 toClaimReserve_, uint256 marketExpenditure_)
    {
        uint256 toFundReserveBeforeExpenditures = (_contributionAfterFee *
            _reserve.dynamicReserveRatio) / 100;

        marketExpenditure_ =
            (toFundReserveBeforeExpenditures * _reserve.fundMarketExpendsAddShare) /
            100;

        toFundReserve_ = toFundReserveBeforeExpenditures - marketExpenditure_;
        toClaimReserve_ = _contributionAfterFee - toFundReserveBeforeExpenditures;

        emit TakasureEvents.OnNewReserveValues(
            _reserve.totalContributions,
            _reserve.totalClaimReserve,
            _reserve.totalFundReserve,
            _reserve.totalFundCost
        );
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
                    cashFlowVars.dayDepositTimestamp += daysPassed * DAY;
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
                cashFlowVars.monthDepositTimestamp += monthsPassed * MONTH;
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

    function _cashLast12Months() internal view returns (uint256 cashLast12Months_) {
        CashFlowVars memory cashFlowVars = takasureReserve.getCashFlowValues();
        uint16 _currentMonth = cashFlowVars.monthReference;
        uint8 _currentDay = cashFlowVars.dayReference;
        uint256 cash = 0;

        // Then make the iterations, according the month and day this function is called
        if (_currentMonth < 13) {
            // Less than a complete year, iterate through every month passed
            // Return everything stored in the mappings until now
            for (uint8 i = 1; i <= _currentMonth; ++i) {
                cash += takasureReserve.monthToCashFlow(i);
            }
        } else {
            // More than a complete year has passed, iterate the last 11 completed months
            // This happens since month 13
            uint16 monthBackCounter;
            uint16 monthsInYear = 12;

            for (uint8 i; i < monthsInYear; ++i) {
                monthBackCounter = _currentMonth - i;
                cash += takasureReserve.monthToCashFlow(monthBackCounter);
            }

            // Iterate an extra month to complete the days that are left from the current month
            uint16 extraMonthToCheck = _currentMonth - monthsInYear;
            uint8 dayBackCounter = 30;
            uint8 extraDaysToCheck = dayBackCounter - _currentDay;

            for (uint8 i; i < extraDaysToCheck; ++i) {
                cash += takasureReserve.dayToCashFlow(extraMonthToCheck, dayBackCounter);

                unchecked {
                    --dayBackCounter;
                }
            }
        }

        cashLast12Months_ = cash;
    }

    function _updateDRR(
        uint256 _cash,
        Reserve memory _reserve
    ) internal returns (uint256 updatedDynamicReserveRatio_) {
        updatedDynamicReserveRatio_ = ReserveMathLib._calculateDynamicReserveRatio(
            _reserve.initialReserveRatio,
            _reserve.proFormaFundReserve,
            _reserve.totalFundReserve,
            _cash
        );

        emit TakasureEvents.OnNewDynamicReserveRatio(updatedDynamicReserveRatio_);
    }

    function _updateBMA(
        uint256 _cash,
        Reserve memory _reserve
    ) internal returns (uint256 updatedBMA_) {
        uint256 bmaInflowAssumption = ReserveMathLib._calculateBmaInflowAssumption(
            _cash,
            _reserve.serviceFee,
            _reserve.initialReserveRatio
        );

        updatedBMA_ = ReserveMathLib._calculateBmaCashFlowMethod(
            _reserve.totalClaimReserve,
            _reserve.totalFundReserve,
            _reserve.bmaFundReserveShare,
            _reserve.proFormaClaimReserve,
            bmaInflowAssumption
        );

        emit TakasureEvents.OnNewBenefitMultiplierAdjuster(updatedBMA_);
    }

    function _updateLossRatio(
        uint256 _totalFundCost,
        uint256 _totalFundRevenues
    ) internal returns (uint256 lossRatio_) {
        lossRatio_ = ReserveMathLib._calculateLossRatio(_totalFundCost, _totalFundRevenues);
        emit TakasureEvents.OnNewLossRatio(lossRatio_);
    }

    function _mintDaoTokens(uint256 _contributionBeforeFee) internal  {
        // Mint needed DAO Tokens
        Reserve memory _reserve = takasureReserve.getReserveValues();
        mintedTokens = _contributionBeforeFee * DECIMALS_PRECISION; // 6 decimals to 18 decimals

        bool success = ITSToken(_reserve.daoToken).mint(address(this), mintedTokens);
        require(success, TakasureErrors.Module__MintFailed());
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(TAKADAO_OPERATOR) {}
}
