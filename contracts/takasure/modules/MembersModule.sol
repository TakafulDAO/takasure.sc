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
import {CommonConstants} from "contracts/libraries/CommonConstants.sol";
import {PaymentAlgorithms} from "contracts/libraries/PaymentAlgorithms.sol";
import {ReserveAndMemberValues} from "contracts/libraries/ReserveAndMemberValues.sol";
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


    uint256 private constant DECIMALS_PRECISION = 1e12;

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
        _grantRole(CommonConstants.TAKADAO_OPERATOR, takadaoOperator);
    }

    function recurringPayment() external nonReentrant {
        (Reserve memory reserve, Member memory newMember) = ReserveAndMemberValues._getReserveAndMemberValuesHook(
            takasureReserve, msg.sender
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
        reserve = _memberRecurringPaymentFlow({
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

        ReserveAndMemberValues._setNewReserveAndMemberValuesHook(takasureReserve, reserve, newMember);
        takasureReserve.memberSurplus(newMember);
    }

    /**
     * @notice This function will update all the variables needed when a member pays the contribution
     * @dev It transfer the contribution from the module to the reserves
     */
    function _memberRecurringPaymentFlow(
        uint256 _contributionBeforeFee,
        uint256 _contributionAfterFee,
        address _memberWallet,
        Reserve memory _reserve
    ) internal returns (Reserve memory) {
        _reserve = PaymentAlgorithms._updateNewReserveValues(takasureReserve, _contributionAfterFee, _contributionBeforeFee, _reserve);

         IERC20(_reserve.contributionToken).safeTransferFrom(
            _memberWallet,
            address(takasureReserve),
            _contributionAfterFee
        );

        // Mint the DAO Tokens
        _mintDaoTokens(_contributionBeforeFee);

        return _reserve;
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
    ) internal override onlyRole(CommonConstants.TAKADAO_OPERATOR) {}
}
