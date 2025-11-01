//SPDX-License-Identifier: GPL-3.0

/**
 * @title MemberModule
 * @author Maikel Ordaz
 * @notice This contract will manage defaults, cancelations and recurring payments. On the Association and
 *         benefits
 * @dev It will interact with the TakasureReserve and/or SubscriptionModule contract to update the corresponding values
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {IProtocolStorageModule} from "contracts/interfaces/modules/IProtocolStorageModule.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {ModuleImplementation} from "contracts/modules/moduleUtils/ModuleImplementation.sol";
import {MemberPaymentFlow} from "contracts/helpers/payments/MemberPaymentFlow.sol";

import {Reserve, BenefitMember, BenefitMemberState, ModuleState, AssociationMember, AssociationMemberState} from "contracts/types/TakasureTypes.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract ManageSubscriptionModule is
    ModuleImplementation,
    MemberPaymentFlow,
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error MemberModule__InvalidDate();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _addressManager, string calldata _moduleName) external initializer {
        AddressAndStates._notZeroAddress(_addressManager);
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();

        addressManager = IAddressManager(_addressManager);
        moduleName = _moduleName;
    }

    /*//////////////////////////////////////////////////////////////
                              ASSOCIATION
    //////////////////////////////////////////////////////////////*/

    function payRecurringAssociationSubscription(
        address memberWallet,
        bool payAssociationSubscription,
        uint256 associationCouponAmount
    ) external nonReentrant {
        // Checks
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled,
            address(this),
            IAddressManager(addressManager).getProtocolAddressByName("MODULE_MANAGER").addr
        );

        // Pay for the selected services
        if (payAssociationSubscription)
            _payRecurringAssociationSubscription(memberWallet, associationCouponAmount);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _payRecurringAssociationSubscription(
        address _memberWallet,
        uint256 _associationCouponAmount
    ) internal {
        require(
            _associationCouponAmount == 0 ||
                _associationCouponAmount == ModuleConstants.ASSOCIATION_SUBSCRIPTION,
            ModuleErrors.Module__InvalidCoupon()
        );

        (
            IProtocolStorageModule protocolStorageModule,
            AssociationMember memory associationMember
        ) = _fetchMemberFromStorageModule(_memberWallet);

        // Validate the date, it should be able to pay only if the grace period for the next payment is not reached
        require(
            block.timestamp <=
                associationMember.latestPaymentTimestamp +
                    ModuleConstants.YEAR +
                    ModuleConstants.MONTH,
            MemberModule__InvalidDate()
        );

        require(
            associationMember.memberState == AssociationMemberState.Active,
            ModuleErrors.Module__WrongMemberState()
        );

        uint256 newLatestPaymentTimestamp = associationMember.latestPaymentTimestamp +
            ModuleConstants.YEAR;

        associationMember.latestPaymentTimestamp = newLatestPaymentTimestamp;

        IERC20 contributionToken = IERC20(
            addressManager.getProtocolAddressByName("CONTRIBUTION_TOKEN").addr
        );

        uint256 fee = (ModuleConstants.ASSOCIATION_SUBSCRIPTION *
            ModuleConstants.ASSOCIATION_SUBSCRIPTION_FEE) / 100;
        uint256 toTransfer = ModuleConstants.ASSOCIATION_SUBSCRIPTION - fee;

        address feeClaimer = addressManager.getProtocolAddressByName("FEE_CLAIM_ADDRESS").addr;

        if (_associationCouponAmount == 0) {
            // The caller must be the member wallet
            require(msg.sender == _memberWallet, ModuleErrors.Module__NotAuthorizedCaller());

            // In this case, the user is paying with their wallet
            contributionToken.safeTransferFrom(msg.sender, address(this), toTransfer);
            contributionToken.safeTransferFrom(msg.sender, feeClaimer, fee);
        } else {
            // Able to be called by the backend admin (for automations)
            require(
                AddressAndStates._checkRole(Roles.BACKEND_ADMIN, address(addressManager)),
                ModuleErrors.Module__NotAuthorizedCaller()
            );

            address couponPoolAddress = addressManager.getProtocolAddressByName("COUPON_POOL").addr;

            // In this case, the payment comes from the coupon pool
            contributionToken.safeTransferFrom(couponPoolAddress, address(this), toTransfer);
            contributionToken.safeTransferFrom(couponPoolAddress, feeClaimer, fee);
        }

        protocolStorageModule.updateAssociationMember(associationMember);

        emit TakasureEvents.OnRecurringAssociationPayment(
            _memberWallet,
            associationMember.memberId
        );
    }

    function _fetchMemberFromStorageModule(
        address _userWallet
    )
        internal
        view
        returns (IProtocolStorageModule protocolStorageModule_, AssociationMember memory member_)
    {
        protocolStorageModule_ = IProtocolStorageModule(
            addressManager.getProtocolAddressByName("PROTOCOL_STORAGE_MODULE").addr
        );

        // Get the member from storage
        member_ = protocolStorageModule_.getAssociationMember(_userWallet);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(Roles.OPERATOR, address(addressManager)) {}
}
