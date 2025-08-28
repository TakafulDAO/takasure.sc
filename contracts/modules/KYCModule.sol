//SPDX-License-Identifier: GPL-3.0

/**
 * @title KYCModule
 * @author Maikel Ordaz
 * @notice This contract manage the KYC flow
 * @dev It will interact with the TakasureReserve contract to update the values. Only admin functions
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {ISubscriptionModule} from "contracts/interfaces/ISubscriptionModule.sol";
import {IAddressManager} from "contracts/interfaces/IAddressManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";
import {ReserveAndMemberValuesHook} from "contracts/hooks/ReserveAndMemberValuesHook.sol";
import {MemberPaymentFlow} from "contracts/helpers/payments/MemberPaymentFlow.sol";
import {ParentRewards} from "contracts/helpers/payments/ParentRewards.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";

import {Reserve, Member, MemberState, ModuleState, ProtocolAddress} from "contracts/types/TakasureTypes.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

pragma solidity 0.8.28;

contract KYCModule is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    TLDModuleImplementation,
    ReserveAndMemberValuesHook,
    MemberPaymentFlow,
    ParentRewards
{
    ITakasureReserve private takasureReserve;

    error KYCModule__ContributionRequired();
    error KYCModule__BenefitMultiplierRequestFailed(bytes errorResponse);
    error KYCModule__MemberAlreadyKYCed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _takasureReserveAddress) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();

        takasureReserve = ITakasureReserve(_takasureReserveAddress);
    }

    /**
     * @notice Set the module state
     * @dev Only callable from the Module Manager
     */
    function setContractState(
        ModuleState newState
    ) external override onlyContract("MODULE_MANAGER", address(takasureReserve.addressManager())) {
        moduleState = newState;
    }

    /**
     * @notice Approves the KYC for a member.
     * @param memberWallet address of the member
     * @dev It reverts if the member is the zero address
     * @dev It reverts if the member is already KYCed
     */
    function approveKYC(
        address memberWallet,
        uint256 benefitMultiplier
    ) external onlyRole(Roles.KYC_PROVIDER, address(takasureReserve.addressManager())) {
        AddressAndStates._onlyModuleState(moduleState, ModuleState.Enabled);
        AddressAndStates._notZeroAddress(memberWallet);

        (Reserve memory reserve, Member memory newMember) = _getReserveAndMemberValuesHook(
            takasureReserve,
            memberWallet
        );

        require(!newMember.isKYCVerified, KYCModule__MemberAlreadyKYCed());
        require(
            newMember.contribution > 0 && !newMember.isRefunded,
            KYCModule__ContributionRequired()
        );

        // We update the member values
        newMember.benefitMultiplier = benefitMultiplier;
        newMember.membershipStartTime = block.timestamp;
        newMember.memberState = MemberState.Active; // Active state as the user is already paid the contribution and KYCed
        newMember.isKYCVerified = true;

        // Then the everyting needed will be updated, proformas, reserves, cash flow,
        // DRR, BMA, tokens minted, no need to transfer the amounts as they are already paid
        uint256 credits;
        (reserve, credits) = _memberPaymentFlow({
            _contributionBeforeFee: newMember.contribution,
            _contributionAfterFee: newMember.contribution -
                ((newMember.contribution * reserve.serviceFee) / 100),
            _memberWallet: memberWallet,
            _reserve: reserve,
            _takasureReserve: takasureReserve
        });

        newMember.creditsBalance += credits;

        // Reward the parents
        address parent = childToParent[memberWallet];

        for (uint256 i; i < uint256(MAX_TIER); ++i) {
            if (parent == address(0)) break;

            uint256 layer = i + 1;

            uint256 parentReward = parentRewardsByChild[parent][memberWallet];

            // Reset the rewards for this child
            parentRewardsByChild[parent][memberWallet] = 0;

            try IERC20(reserve.contributionToken).transfer(parent, parentReward) {
                emit TakasureEvents.OnParentRewarded(parent, layer, memberWallet, parentReward);
            } catch {
                parentRewardsByChild[parent][memberWallet] = parentReward;
                emit TakasureEvents.OnParentRewardTransferFailed(
                    parent,
                    layer,
                    memberWallet,
                    parentReward
                );
            }
            // We update the parent address to check the next parent
            parent = childToParent[parent];
        }

        emit TakasureEvents.OnMemberKycVerified(newMember.memberId, memberWallet);
        emit TakasureEvents.OnMemberJoined(newMember.memberId, memberWallet);

        _setNewReserveAndMemberValuesHook(takasureReserve, reserve, newMember);
        takasureReserve.memberSurplus(newMember);
    }

    function _transferContributionToReserve(
        IERC20 _contributionToken,
        address _memberWallet,
        address _takasureReserve,
        uint256 _contributionAfterFee
    ) internal override {
        address addressManager = address(ITakasureReserve(_takasureReserve).addressManager());
        address subscriptionModuleAddress = IAddressManager(addressManager)
            .getProtocolAddressByName("SUBSCRIPTION_MODULE")
            .addr;

        ISubscriptionModule subscriptionModule = ISubscriptionModule(subscriptionModuleAddress);

        subscriptionModule.transferContributionAfterKyc(
            _contributionToken,
            _memberWallet,
            _takasureReserve,
            _contributionAfterFee
        );
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(Roles.OPERATOR, address(takasureReserve.addressManager())) {}
}
