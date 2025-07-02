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
import {IReferralRewardsModule} from "contracts/interfaces/IReferralRewardsModule.sol";
import {IAddressManager} from "contracts/interfaces/IAddressManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";
import {MemberValuesHook} from "contracts/hooks/MemberValuesHook.sol";
import {MemberPaymentFlow} from "contracts/helpers/payments/MemberPaymentFlow.sol";
import {ParentRewards} from "contracts/helpers/payments/ParentRewards.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";

import {AssociationMember, AssociationMemberState, ModuleState, ProtocolAddress} from "contracts/types/TakasureTypes.sol";
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
    MemberValuesHook,
    MemberPaymentFlow,
    ParentRewards
{
    IAddressManager private addressManager;
    ModuleState private moduleState;

    string public moduleName;

    mapping(address member => bool) public isKYCed; // To check if a member is KYCed

    error KYCModule__ContributionRequired();
    error KYCModule__BenefitMultiplierRequestFailed(bytes errorResponse);
    error KYCModule__MemberAlreadyKYCed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _addressManager, string calldata _moduleName) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();

        addressManager = IAddressManager(_addressManager);
        moduleName = _moduleName;
    }

    /**
     * @notice Set the module state
     * @dev Only callable from the Module Manager
     */
    function setContractState(
        ModuleState newState
    ) external override onlyContract("MODULE_MANAGER", address(addressManager)) {
        moduleState = newState;
    }

    /**
     * @notice Approves the KYC for a member.
     * @param memberWallet address of the member
     * @dev It reverts if the member is the zero address
     * @dev It reverts if the member is already KYCed
     */
    function approveKYC(
        address memberWallet
    ) external onlyRole(Roles.KYC_PROVIDER, address(addressManager)) {
        AddressAndStates._onlyModuleState(moduleState, ModuleState.Enabled);
        AddressAndStates._notZeroAddress(memberWallet);

        require(!isKYCed[memberWallet], KYCModule__MemberAlreadyKYCed());

        AssociationMember memory newMember = _getAssociationMembersValuesHook(
            addressManager,
            memberWallet
        );
        require(!newMember.isRefunded, KYCModule__ContributionRequired());

        // We update the member values
        newMember.memberState = AssociationMemberState.Active; // Active state as the user is already paid the contribution and KYCed
        isKYCed[memberWallet] = true;

        // Reward the parents
        IReferralRewardsModule(
            addressManager.getProtocolAddressByName("REFERRAL_REWARDS_MODULE").addr
        ).rewardParentsFromSubscriptions(memberWallet);

        emit TakasureEvents.OnMemberKycVerified(newMember.memberId, memberWallet);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(Roles.OPERATOR, address(addressManager)) {}
}
