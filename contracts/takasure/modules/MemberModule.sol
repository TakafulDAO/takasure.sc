//SPDX-License-Identifier: GPL-3.0

/**
 * @title MemberModule
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
import {ModuleCheck} from "contracts/takasure/modules/moduleUtils/ModuleCheck.sol";
import {ReserveAndMemberValuesHook} from "contracts/hooks/ReserveAndMemberValuesHook.sol";

import {Reserve, Member, MemberState, RevenueType, CashFlowVars} from "contracts/types/TakasureTypes.sol";
import {ModuleConstants} from "contracts/helpers/libraries/ModuleConstants.sol";
import {CashFlowAlgorithms} from "contracts/helpers/libraries/CashFlowAlgorithms.sol";
import {TakasureEvents} from "contracts/helpers/libraries/TakasureEvents.sol";
import {GlobalErrors} from "contracts/helpers/libraries/GlobalErrors.sol";
import {ModuleErrors} from "contracts/helpers/libraries/ModuleErrors.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract MemberModule is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    ModuleCheck,
    ReserveAndMemberValuesHook
{
    using SafeERC20 for IERC20;

    ITakasureReserve private takasureReserve;
    IBenefitMultiplierConsumer private bmConsumer;

    uint256 private transient mintedTokens;

    error MemberModule__InvalidDate();

    modifier notZeroAddress(address _address) {
        require(_address != address(0), GlobalErrors.TakasureProtocol__ZeroAddress());
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
        _grantRole(ModuleConstants.TAKADAO_OPERATOR, takadaoOperator);
    }

    /**
     * @notice Method to cancel a membership
     * @dev To be called by anyone
     */
    function cancelMembership(address memberWallet) external notZeroAddress(memberWallet) {
        _cancelMembership(memberWallet);
    }

    function payRecurringContribution(address memberWallet) external nonReentrant {
        (Reserve memory reserve, Member memory activeMember) = _getReserveAndMemberValuesHook(
            takasureReserve,
            memberWallet
        );

        require(
            activeMember.memberState == MemberState.Active &&
                activeMember.memberState != MemberState.Defaulted,
            ModuleErrors.Module__WrongMemberState()
        );

        uint256 currentTimestamp = block.timestamp;
        uint256 membershipStartTime = activeMember.membershipStartTime;
        uint256 membershipDuration = activeMember.membershipDuration;
        uint256 lastPaidYearStartDate = activeMember.lastPaidYearStartDate;
        uint256 year = 365 days;
        uint256 gracePeriod = 30 days;

        require(
            currentTimestamp <= membershipStartTime + membershipDuration &&
                currentTimestamp < lastPaidYearStartDate + year + gracePeriod,
            MemberModule__InvalidDate()
        );

        uint256 contributionBeforeFee = activeMember.contribution;
        uint256 feeAmount = (contributionBeforeFee * reserve.serviceFee) / 100;
        uint256 contributionAfterFee = contributionBeforeFee - feeAmount;

        // Update the values
        activeMember.lastPaidYearStartDate += 365 days;
        activeMember.totalContributions += contributionBeforeFee;
        activeMember.totalServiceFee += feeAmount;
        activeMember.lastEcr = 0;
        activeMember.lastUcr = 0;

        // And we pay the contribution
        reserve = _memberRecurringPaymentFlow({
            _contributionBeforeFee: contributionBeforeFee,
            _contributionAfterFee: contributionAfterFee,
            _memberWallet: memberWallet,
            _reserve: reserve
        });

        activeMember.creditTokensBalance += mintedTokens;

        emit TakasureEvents.OnRecurringPayment(
            memberWallet,
            activeMember.memberId,
            activeMember.lastPaidYearStartDate,
            contributionBeforeFee,
            activeMember.totalServiceFee
        );

        _setNewReserveAndMemberValuesHook(takasureReserve, reserve, activeMember);
        takasureReserve.memberSurplus(activeMember);
    }

    function defaultMember(address memberWallet) external {
        Member memory member = _getMembersValuesHook(takasureReserve, memberWallet);

        require(member.memberState == MemberState.Active, ModuleErrors.Module__WrongMemberState());

        uint256 currentTimestamp = block.timestamp;
        uint256 lastPaidYearStartDate = member.lastPaidYearStartDate;
        uint256 limitTimestamp = member.membershipStartTime + lastPaidYearStartDate;

        if (currentTimestamp >= limitTimestamp) {
            // Update the state, this will allow to cancel the membership
            member.memberState = MemberState.Defaulted;

            emit TakasureEvents.OnMemberDefaulted(member.memberId, msg.sender);

            _setMembersValuesHook(takasureReserve, member);
        } else {
            revert ModuleErrors.Module__TooEarlyToDefault();
        }
    }

    function _cancelMembership(address _memberWallet) internal {
        Member memory member = _getMembersValuesHook(takasureReserve, _memberWallet);

        require(
            member.memberState == MemberState.Defaulted,
            ModuleErrors.Module__WrongMemberState()
        );

        // To cancel the member should be defaulted and at least 30 days have passed from the new year
        uint256 currentTimestamp = block.timestamp;
        uint256 limitTimestamp = member.membershipStartTime +
            member.lastPaidYearStartDate +
            (30 days);

        if (currentTimestamp >= limitTimestamp) {
            member.memberState = MemberState.Canceled;

            emit TakasureEvents.OnMemberCanceled(member.memberId, _memberWallet);

            _setMembersValuesHook(takasureReserve, member);
        } else {
            revert ModuleErrors.Module__TooEarlyToCancel();
        }
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
        _reserve = CashFlowAlgorithms._updateNewReserveValues(
            takasureReserve,
            _contributionAfterFee,
            _contributionBeforeFee,
            _reserve
        );

        IERC20(_reserve.contributionToken).safeTransferFrom(
            _memberWallet,
            address(takasureReserve),
            _contributionAfterFee
        );

        // Mint the DAO Tokens
        mintedTokens = CashFlowAlgorithms._mintDaoTokens(takasureReserve, _contributionBeforeFee);

        return _reserve;
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(ModuleConstants.TAKADAO_OPERATOR) {}
}
