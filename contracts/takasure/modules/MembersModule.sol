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

import {NewReserve, Member, MemberState, RevenueType} from "contracts/types/TakasureTypes.sol";
import {ReserveMathLib} from "contracts/libraries/ReserveMathLib.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {TakasureErrors} from "contracts/libraries/TakasureErrors.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

pragma solidity 0.8.25;

contract MembersModule is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransientUpgradeable
{
    ITakasureReserve private takasureReserve;
    IBenefitMultiplierConsumer private bmConsumer;

    bytes32 public constant TAKADAO_OPERATOR = keccak256("TAKADAO_OPERATOR");

    uint256 private constant DECIMALS_PRECISION = 1e12;
    uint256 private constant MONTH = 30 days; // Todo: manage a better way for 365 days and leap years maybe?
    uint256 private constant DAY = 1 days;

    uint256 private dayDepositTimestamp; // 0 at begining, then never is zero again
    uint256 private monthDepositTimestamp; // 0 at begining, then never is zero again
    uint16 private monthReference; // Will count the month. For gas issues will grow undefinitely
    uint8 private dayReference; // Will count the day of the month from 1 -> 30, then resets to 1

    mapping(uint16 month => uint256 montCashFlow) private monthToCashFlow;
    mapping(uint16 month => mapping(uint8 day => uint256 dayCashFlow)) private dayToCashFlow; // ? Maybe better block.timestamp => dailyDeposits for this one?

    modifier notZeroAddress(address _address) {
        if (_address == address(0)) {
            revert TakasureErrors.TakasurePool__ZeroAddress();
        }
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

        monthReference = 1;
        dayReference = 1;
    }

    function recurringPayment() external nonReentrant {
        (NewReserve memory newReserve, Member memory newMember) = _getReserveAndMemberValuesHook(
            msg.sender
        );

        if (newMember.memberState != MemberState.Active) {
            revert TakasureErrors.TakasurePool__WrongMemberState();
        }
        uint256 currentTimestamp = block.timestamp;
        uint256 membershipStartTime = newMember.membershipStartTime;
        uint256 membershipDuration = newMember.membershipDuration;
        uint256 lastPaidYearStartDate = newMember.lastPaidYearStartDate;
        uint256 year = 365 days;
        uint256 gracePeriod = 30 days;

        if (
            currentTimestamp > lastPaidYearStartDate + year + gracePeriod ||
            currentTimestamp > membershipStartTime + membershipDuration
        ) {
            revert TakasureErrors.TakasurePool__InvalidDate();
        }

        uint256 contributionBeforeFee = newMember.contribution;
        uint256 feeAmount = (contributionBeforeFee * newReserve.serviceFee) / 100;
        uint256 contributionAfterFee = contributionBeforeFee - feeAmount;

        // Update the values
        newMember.lastPaidYearStartDate += 365 days;
        newMember.totalContributions += contributionBeforeFee;
        newMember.totalServiceFee += feeAmount;
        newMember.lastEcr = 0;
        newMember.lastUcr = 0;

        // And we pay the contribution
        _memberPaymentFlow({
            _contributionBeforeFee: contributionBeforeFee,
            _contributionAfterFee: contributionAfterFee,
            _memberWallet: msg.sender,
            _payContribution: true,
            _reserve: newReserve
        });

        emit TakasureEvents.OnRecurringPayment(
            msg.sender,
            newMember.memberId,
            newMember.lastPaidYearStartDate,
            newMember.totalContributions,
            newMember.totalServiceFee
        );

        _setNewReserveAndMemberValuesHook(newReserve, newMember);
    }

    function _getReserveAndMemberValuesHook(
        address _memberWallet
    ) internal view returns (NewReserve memory reserve_, Member memory member_) {
        reserve_ = takasureReserve.getReserveValues();
        member_ = takasureReserve.getMemberFromAddress(_memberWallet);
    }

    function _setNewReserveAndMemberValuesHook(
        NewReserve memory _newReserve,
        Member memory _newMember
    ) internal {
        takasureReserve.setReserveValuesFromModule(_newReserve);
        takasureReserve.setMemberValuesFromModule(_newMember);
    }

    /**
     * @notice This function will update all the variables needed when a member pays the contribution
     * @param _payContribution true -> the contribution will be paid and the credit tokens will be minted
     *                                      false -> no need to pay the contribution as it is already payed
     */
    function _memberPaymentFlow(
        uint256 _contributionBeforeFee,
        uint256 _contributionAfterFee,
        address _memberWallet,
        bool _payContribution,
        NewReserve memory _reserve
    ) internal returns (NewReserve memory) {
        _getBenefitMultiplierFromOracle(_memberWallet);

        _reserve = _updateNewReserveValues(_contributionAfterFee, _contributionBeforeFee, _reserve);

        if (_payContribution) {
            _transferAmounts(_contributionAfterFee, _contributionBeforeFee, _memberWallet, true);
        }

        return _reserve;
    }

    function _getBenefitMultiplierFromOracle(
        address _member
    ) internal returns (uint256 benefitMultiplier_) {
        Member memory member = takasureReserve.getMemberFromAddress(_member);
        string memory memberAddressToString = Strings.toHexString(uint256(uint160(_member)), 20);

        // First we check if there is already a request id for this member
        bytes32 requestId = bmConsumer.memberToRequestId(memberAddressToString);

        if (requestId == 0) {
            // If there is no request id, it means the member has no valid BM yet. So we make a new request
            string[] memory args = new string[](1);
            args[0] = memberAddressToString;
            bmConsumer.sendRequest(args);
        } else {
            // If there is a request id, we check if it was successful
            bool successRequest = bmConsumer.idToSuccessRequest(requestId);

            if (successRequest) {
                benefitMultiplier_ = bmConsumer.idToBenefitMultiplier(requestId);
                member.benefitMultiplier = benefitMultiplier_;
            } else {
                // If failed we get the error and revert with it
                bytes memory errorResponse = bmConsumer.idToErrorResponse(requestId);
                revert TakasureErrors.TakasurePool__BenefitMultiplierRequestFailed(errorResponse);
            }
        }
    }

    function _updateNewReserveValues(
        uint256 _contributionAfterFee,
        uint256 _contributionBeforeFee,
        NewReserve memory _reserve
    ) internal returns (NewReserve memory) {
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
        uint256 cashLast12Months = _cashLast12Months(monthReference, dayReference);

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
        NewReserve memory _reserve
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
        NewReserve memory _reserve
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
        uint256 currentTimestamp = block.timestamp;

        if (dayDepositTimestamp == 0 && monthDepositTimestamp == 0) {
            // If the depositTimestamp is 0 it means it is the first deposit
            // Set the initial values for future calculations and reference
            dayDepositTimestamp = currentTimestamp;
            monthDepositTimestamp = currentTimestamp;
            monthToCashFlow[monthReference] = _cashIn;
            dayToCashFlow[monthReference][dayReference] = _cashIn;
        } else {
            // Check how many days and months have passed since the last deposit
            uint256 daysPassed = ReserveMathLib._calculateDaysPassed(
                currentTimestamp,
                dayDepositTimestamp
            );
            uint256 monthsPassed = ReserveMathLib._calculateMonthsPassed(
                currentTimestamp,
                monthDepositTimestamp
            );

            if (monthsPassed == 0) {
                // If no months have passed, update the mapping for the current month
                monthToCashFlow[monthReference] += _cashIn;
                if (daysPassed == 0) {
                    // If no days have passed, update the mapping for the current day
                    dayToCashFlow[monthReference][dayReference] += _cashIn;
                } else {
                    // If it is a new day, update the day deposit timestamp and the new day reference
                    dayDepositTimestamp += daysPassed * DAY;
                    dayReference += uint8(daysPassed);

                    // Update the mapping for the new day
                    dayToCashFlow[monthReference][dayReference] = _cashIn;
                }
            } else {
                // If it is a new month, update the month deposit timestamp and the day deposit timestamp
                // both should be the same as it is a new month
                monthDepositTimestamp += monthsPassed * MONTH;
                dayDepositTimestamp = monthDepositTimestamp;
                // Update the month reference to the corresponding month
                monthReference += uint16(monthsPassed);
                // Calculate the day reference for the new month, we need to recalculate the days passed
                // with the new day deposit timestamp
                daysPassed = ReserveMathLib._calculateDaysPassed(
                    currentTimestamp,
                    dayDepositTimestamp
                );
                // The new day reference is the days passed + initial day. Initial day refers
                // to the first day of the month
                uint8 initialDay = 1;
                dayReference = uint8(daysPassed) + initialDay;

                // Update the mappings for the new month and day
                monthToCashFlow[monthReference] = _cashIn;
                dayToCashFlow[monthReference][dayReference] = _cashIn;
            }
        }
    }

    function _cashLast12Months(
        uint16 _currentMonth,
        uint8 _currentDay
    ) internal view returns (uint256 cashLast12Months_) {
        uint256 cash = 0;

        // Then make the iterations, according the month and day this function is called
        if (_currentMonth < 13) {
            // Less than a complete year, iterate through every month passed
            // Return everything stored in the mappings until now
            for (uint8 i = 1; i <= _currentMonth; ) {
                cash += monthToCashFlow[i];

                unchecked {
                    ++i;
                }
            }
        } else {
            // More than a complete year has passed, iterate the last 11 completed months
            // This happens since month 13
            uint16 monthBackCounter;
            uint16 monthsInYear = 12;

            for (uint8 i; i < monthsInYear; ) {
                monthBackCounter = _currentMonth - i;
                cash += monthToCashFlow[monthBackCounter];

                unchecked {
                    ++i;
                }
            }

            // Iterate an extra month to complete the days that are left from the current month
            uint16 extraMonthToCheck = _currentMonth - monthsInYear;
            uint8 dayBackCounter = 30;
            uint8 extraDaysToCheck = dayBackCounter - _currentDay;

            for (uint8 i; i < extraDaysToCheck; ) {
                cash += dayToCashFlow[extraMonthToCheck][dayBackCounter];

                unchecked {
                    ++i;
                    --dayBackCounter;
                }
            }
        }

        cashLast12Months_ = cash;
    }

    function _updateDRR(
        uint256 _cash,
        NewReserve memory _reserve
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
        NewReserve memory _reserve
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

    function _transferAmounts(
        uint256 _contributionAfterFee,
        uint256 _contributionBeforeFee,
        address _memberWallet,
        bool _mintTokens
    ) internal {
        IERC20 contributionToken = IERC20(takasureReserve.getReserveValues().contributionToken);
        bool success;
        uint256 feeAmount = _contributionBeforeFee - _contributionAfterFee;

        // Transfer the contribution to the pool
        success = contributionToken.transferFrom(
            _memberWallet,
            address(this),
            _contributionAfterFee
        );
        if (!success) {
            revert TakasureErrors.TakasurePool__ContributionTransferFailed();
        }

        // Transfer the service fee to the fee claim address
        success = contributionToken.transferFrom(
            _memberWallet,
            takasureReserve.feeClaimAddress(),
            feeAmount
        );
        if (!success) {
            revert TakasureErrors.TakasurePool__FeeTransferFailed();
        }

        if (_mintTokens) {
            uint256 contributionBeforeFee = _contributionAfterFee + feeAmount;
            _mintDaoTokens(contributionBeforeFee, _memberWallet);
        }
    }

    function _mintDaoTokens(uint256 _contributionBeforeFee, address _memberWallet) internal {
        // Mint needed DAO Tokens
        NewReserve memory _newReserve = takasureReserve.getReserveValues();
        Member memory member = takasureReserve.getMemberFromAddress(_memberWallet);
        uint256 mintAmount = _contributionBeforeFee * DECIMALS_PRECISION; // 6 decimals to 18 decimals
        member.creditTokensBalance = mintAmount;

        bool success = ITSToken(_newReserve.daoToken).mint(address(this), mintAmount);
        if (!success) {
            revert TakasureErrors.TakasurePool__MintFailed();
        }
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(TAKADAO_OPERATOR) {}
}
