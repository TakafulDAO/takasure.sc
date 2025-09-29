//SPDX-License-Identifier: GPL-3.0

/**
 * @title MemberModule
 * @author Maikel Ordaz
 * @notice This contract will manage defaults, cancelations and recurring payments
 * @dev It will interact with the TakasureReserve contract to update the values
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {IAddressManager} from "contracts/interfaces/IAddressManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {ModuleImplementation} from "contracts/modules/moduleUtils/ModuleImplementation.sol";
import {ReserveAndMemberValuesHook} from "contracts/hooks/ReserveAndMemberValuesHook.sol";
import {MemberPaymentFlow} from "contracts/helpers/payments/MemberPaymentFlow.sol";

import {Reserve, Member, MemberState, ModuleState} from "contracts/types/TakasureTypes.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract MemberModule is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    ModuleImplementation,
    ReserveAndMemberValuesHook,
    MemberPaymentFlow
{
    using SafeERC20 for IERC20;

    ITakasureReserve private takasureReserve;

    error MemberModule__InvalidDate();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _takasureReserveAddress) external initializer {
        AddressAndStates._notZeroAddress(_takasureReserveAddress);
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();

        takasureReserve = ITakasureReserve(_takasureReserveAddress);
    }

    /**
     * @notice Method to cancel a membership
     * @dev To be called by anyone
     */
    function cancelMembership(address memberWallet) external {
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled,
            address(this),
            IAddressManager(addressManager).getProtocolAddressByName("MODULE_MANAGER").addr
        );
        AddressAndStates._notZeroAddress(memberWallet);
        _cancelMembership(memberWallet);
    }

    function payRecurringContribution(address memberWallet) external nonReentrant {
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled,
            address(this),
            IAddressManager(addressManager).getProtocolAddressByName("MODULE_MANAGER").addr
        );

        require(
            AddressAndStates._checkName("ROUTER", address(takasureReserve.addressManager())) ||
                msg.sender == memberWallet,
            ModuleErrors.Module__NotAuthorizedCaller()
        );

        (Reserve memory reserve, Member memory activeMember) = _getReserveAndMemberValuesHook(
            takasureReserve,
            memberWallet
        );

        require(
            activeMember.memberState == MemberState.Active ||
                activeMember.memberState == MemberState.Defaulted,
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

        // Update the values
        activeMember.lastPaidYearStartDate += 365 days;
        activeMember.totalContributions += contributionBeforeFee;
        activeMember.totalServiceFee += feeAmount;
        activeMember.lastEcr = 0;
        activeMember.lastUcr = 0;
        if (activeMember.memberState == MemberState.Defaulted)
            activeMember.memberState = MemberState.Active;

        // And we pay the contribution
        uint256 credits;

        (reserve, credits) = _memberPaymentFlow({
            _contributionBeforeFee: contributionBeforeFee,
            _contributionAfterFee: contributionBeforeFee - feeAmount,
            _memberWallet: memberWallet,
            _reserve: reserve,
            _takasureReserve: takasureReserve
        });

        activeMember.creditsBalance += credits;

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
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled,
            address(this),
            IAddressManager(addressManager).getProtocolAddressByName("MODULE_MANAGER").addr
        );
        Member memory member = _getMembersValuesHook(takasureReserve, memberWallet);

        require(member.memberState == MemberState.Active, ModuleErrors.Module__WrongMemberState());

        uint256 currentTimestamp = block.timestamp;
        uint256 lastPaidYearStartDate = member.lastPaidYearStartDate;
        uint256 limitTimestamp = member.membershipStartTime + lastPaidYearStartDate;

        if (currentTimestamp >= limitTimestamp) {
            // Update the state, this will allow to cancel the membership
            member.memberState = MemberState.Defaulted;

            emit TakasureEvents.OnMemberDefaulted(member.memberId, memberWallet);

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

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(Roles.OPERATOR, address(takasureReserve.addressManager())) {}
}
