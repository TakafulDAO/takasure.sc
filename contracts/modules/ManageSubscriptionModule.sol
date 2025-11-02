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

    error ManageSubscriptionModule__InvalidDate();
    error ManageSubscriptionModule__InvalidBenefit();

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
                           RECURRING PAYMENTS
    //////////////////////////////////////////////////////////////*/

    function payRecurringServices(
        address memberWallet,
        bool payAssociationSubscription,
        uint256 associationCouponAmount,
        bool payBenefitSubscriptions,
        address[] calldata benefitAddresses,
        uint256[] calldata benefitCouponAmounts
    ) external nonReentrant returns (bool associationPaid, bool benefitsPaid) {
        // Checks
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled,
            address(this),
            IAddressManager(addressManager).getProtocolAddressByName("MODULE_MANAGER").addr
        );

        // Pay for the selected services
        if (payAssociationSubscription)
            associationPaid = _payRecurringAssociationSubscription(
                memberWallet,
                associationCouponAmount
            );
        if (payBenefitSubscriptions)
            benefitsPaid = _payRecurringBenefitSubscriptions(
                memberWallet,
                benefitAddresses,
                benefitCouponAmounts
            );
    }

    /*//////////////////////////////////////////////////////////////
                                CANCELS
    //////////////////////////////////////////////////////////////*/

    function cancelAssociationSubscription(address memberWallet) external {
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled,
            address(this),
            IAddressManager(addressManager).getProtocolAddressByName("MODULE_MANAGER").addr
        );

        _cancelAssociationSubscription(memberWallet);
    }

    function cancelBenefitSubscriptions(
        address memberWallet,
        address[] calldata benefitAddresses
    ) external {
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled,
            address(this),
            IAddressManager(addressManager).getProtocolAddressByName("MODULE_MANAGER").addr
        );

        _cancelBenefitSubscriptions(memberWallet, benefitAddresses);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _payRecurringAssociationSubscription(
        address _memberWallet,
        uint256 _associationCouponAmount
    ) internal returns (bool) {
        require(
            _associationCouponAmount == 0 ||
                _associationCouponAmount == ModuleConstants.ASSOCIATION_SUBSCRIPTION,
            ModuleErrors.Module__InvalidCoupon()
        );

        (
            IProtocolStorageModule protocolStorageModule,
            AssociationMember memory associationMember
        ) = _fetchAssociationMemberFromStorageModule(_memberWallet);

        // Validate the date, it should be able to pay only if the grace period for the next payment is not reached
        if (
            block.timestamp >
            associationMember.latestPaymentTimestamp + ModuleConstants.YEAR + ModuleConstants.MONTH
        ) {
            _cancelAssociationSubscription(_memberWallet);
            return false;
        }

        require(
            associationMember.memberState == AssociationMemberState.Active,
            ModuleErrors.Module__WrongMemberState()
        );

        uint256 newLatestPaymentTimestamp = associationMember.latestPaymentTimestamp +
            ModuleConstants.YEAR;

        associationMember.latestPaymentTimestamp = newLatestPaymentTimestamp;

        uint256 fee = (ModuleConstants.ASSOCIATION_SUBSCRIPTION *
            ModuleConstants.ASSOCIATION_SUBSCRIPTION_FEE) / 100;
        uint256 toTransfer = ModuleConstants.ASSOCIATION_SUBSCRIPTION - fee;

        if (_associationCouponAmount == 0)
            _performTransfers(_memberWallet, _memberWallet, toTransfer, fee);
        else
            _performTransfers(
                _memberWallet,
                addressManager.getProtocolAddressByName("COUPON_POOL").addr,
                toTransfer,
                fee
            );

        protocolStorageModule.updateAssociationMember(associationMember);

        emit TakasureEvents.OnRecurringAssociationPayment(
            _memberWallet,
            associationMember.memberId
        );

        return true;
    }

    function _payRecurringBenefitSubscriptions(
        address _memberWallet,
        address[] memory _benefitAddresses,
        uint256[] calldata _benefitCouponAmounts
    ) internal returns (bool) {
        require(
            _benefitAddresses.length == _benefitCouponAmounts.length,
            ModuleErrors.Module__InvalidInput()
        );

        _validateBenefits(_memberWallet, _benefitAddresses);

        // Now we loop through all the benefits to pay
        for (uint256 i; i < _benefitAddresses.length; ++i) {
            // The coupon must be within the allowed values
            if (_benefitCouponAmounts[i] > 0)
                require(
                    _benefitCouponAmounts[i] >= ModuleConstants.BENEFIT_MIN_SUBSCRIPTION &&
                        _benefitCouponAmounts[i] <= ModuleConstants.BENEFIT_MAX_SUBSCRIPTION,
                    ModuleErrors.Module__InvalidCoupon()
                );

            (
                IProtocolStorageModule protocolStorageModule,
                BenefitMember memory benefitMember
            ) = _fetchBenefitMemberFromStorageModule(_benefitAddresses[i], _memberWallet);

            if (!_validateDateAndState(benefitMember)) {
                // If the member is late paying more than the grace period, we set the member to Defaulted
                benefitMember.memberState = BenefitMemberState.Canceled;
                protocolStorageModule.updateBenefitMember(_benefitAddresses[i], benefitMember);
                emit TakasureEvents.OnBenefitMemberCanceled(
                    benefitMember.memberId,
                    _benefitAddresses[i],
                    _memberWallet
                );
                return false;
            }

            uint256 benefitFee = protocolStorageModule.getUintValue("benefitFee");
            uint256 toTransfer;
            uint256 fee;

            if (
                addressManager.getProtocolAddressByName("LIFE_BENEFIT_MODULE").addr ==
                _benefitAddresses[i]
            ) {
                // If this is the life benefit, then the amount to pay is reduced by the association recurring payment
                fee =
                    ((benefitMember.contribution - ModuleConstants.ASSOCIATION_SUBSCRIPTION) *
                        benefitFee) /
                    100;
                toTransfer =
                    (benefitMember.contribution - ModuleConstants.ASSOCIATION_SUBSCRIPTION) -
                    fee;
            } else {
                fee = (benefitMember.contribution * benefitFee) / 100;
                toTransfer = benefitMember.contribution - fee;
            }

            if (_benefitCouponAmounts[i] == 0)
                _performTransfers(_memberWallet, _memberWallet, toTransfer, fee);
            else
                _performTransfers(
                    _memberWallet,
                    addressManager.getProtocolAddressByName("COUPON_POOL").addr,
                    toTransfer,
                    fee
                );

            // todo: check other values after benefit modules are ready
            benefitMember.lastPaidYearStartDate =
                benefitMember.lastPaidYearStartDate +
                ModuleConstants.YEAR;
            benefitMember.totalContributions += benefitMember.contribution;
            benefitMember.totalServiceFee += (benefitMember.contribution * benefitFee) / 100;

            protocolStorageModule.updateBenefitMember(_benefitAddresses[i], benefitMember);
            emit TakasureEvents.OnRecurringBenefitPayment(
                _memberWallet,
                benefitMember.memberId,
                benefitMember.lastPaidYearStartDate,
                benefitMember.contribution,
                benefitMember.totalServiceFee
            );
        }

        // todo: we'll need to run model algorithms. Do it later when all benefit modules are ready

        return true;
    }

    function _performTransfers(
        address _userAddress,
        address _from,
        uint256 _contribution,
        uint256 _fee
    ) internal {
        address couponPoolAddress = addressManager.getProtocolAddressByName("COUPON_POOL").addr;
        address feeClaimer = addressManager.getProtocolAddressByName("FEE_CLAIM_ADDRESS").addr;
        address reserve = addressManager.getProtocolAddressByName("TAKASURE_RESERVE").addr;
        IERC20 contributionToken = IERC20(
            addressManager.getProtocolAddressByName("CONTRIBUTION_TOKEN").addr
        );

        if (_from == couponPoolAddress) {
            // Able to be called by the backend admin (for automations)
            require(
                AddressAndStates._checkRole(Roles.BACKEND_ADMIN, address(addressManager)),
                ModuleErrors.Module__NotAuthorizedCaller()
            );

            contributionToken.safeTransferFrom(couponPoolAddress, reserve, _contribution);
            contributionToken.safeTransferFrom(couponPoolAddress, feeClaimer, _fee);
        } else {
            // The caller must be the member wallet
            require(msg.sender == _userAddress, ModuleErrors.Module__NotAuthorizedCaller());

            contributionToken.safeTransferFrom(_userAddress, reserve, _contribution);
            contributionToken.safeTransferFrom(_userAddress, feeClaimer, _fee);
        }
    }

    function _validateBenefits(
        address _memberWallet,
        address[] memory _benefitAddresses
    ) internal view {
        // Get the association member to validate the benefits
        (, AssociationMember memory associationMember) = _fetchAssociationMemberFromStorageModule(
            _memberWallet
        );

        address[] memory memberBenefits = associationMember.benefits;

        // Now we check the benefits addresses belongs to the association member benefits
        // O(M*N) complexity, but N and M are expected to be small numbers
        for (uint256 i; i < _benefitAddresses.length; ++i) {
            address benefit = _benefitAddresses[i];
            bool found;

            for (uint256 j; j < memberBenefits.length; ++j) {
                if (memberBenefits[j] == benefit) {
                    found = true;
                    break;
                }
            }

            require(found, ManageSubscriptionModule__InvalidBenefit());
        }
    }

    function _validateDateAndState(
        BenefitMember memory _benefitMember
    ) internal view returns (bool) {
        require(
            _benefitMember.memberState == BenefitMemberState.Active,
            ModuleErrors.Module__WrongMemberState()
        );

        // Validate the date, it should be able to pay only if the grace period for the next payment is not reached
        if (
            block.timestamp >
            _benefitMember.lastPaidYearStartDate + ModuleConstants.YEAR + ModuleConstants.MONTH
        ) return false;

        return true;
    }

    function _cancelAssociationSubscription(address _memberWallet) internal {
        (
            IProtocolStorageModule protocolStorageModule,
            AssociationMember memory associationMember
        ) = _fetchAssociationMemberFromStorageModule(_memberWallet);

        require(
            associationMember.memberState == AssociationMemberState.Active,
            ModuleErrors.Module__WrongMemberState()
        );

        if (
            block.timestamp <
            associationMember.associateStartTime + ModuleConstants.YEAR + ModuleConstants.MONTH
        ) associationMember.memberState = AssociationMemberState.PendingCancellation;
        else associationMember.memberState = AssociationMemberState.Canceled;

        address[] memory previousBenefits = associationMember.benefits;

        associationMember = AssociationMember({
            memberId: associationMember.memberId,
            discount: 0, // Reset the discount
            couponAmountRedeemed: 0, // Reset the coupon redeemed
            associateStartTime: 0, // Reset the start time
            latestPaymentTimestamp: 0, // Reset the latest payment timestamp
            wallet: _memberWallet,
            parent: address(0), // Reset the parent
            memberState: associationMember.memberState,
            isRefunded: false,
            benefits: new address[](0),
            childs: new address[](0)
        });

        protocolStorageModule.updateAssociationMember(associationMember);

        emit TakasureEvents.OnAssociationMemberCanceled(associationMember.memberId, _memberWallet);

        // Now cancel all the benefit subscriptions
        _cancelBenefitSubscriptions(_memberWallet, previousBenefits);
    }

    function _cancelBenefitSubscriptions(
        address _memberWallet,
        address[] memory _benefitAddresses
    ) internal {
        // Validate the benefits
        _validateBenefits(_memberWallet, _benefitAddresses);

        (
            IProtocolStorageModule protocolStorageModule,
            AssociationMember memory associationMember
        ) = _fetchAssociationMemberFromStorageModule(_memberWallet);

        // Track the benefits that actually become CANCELED (only these are removed)
        address[] memory canceled = new address[](_benefitAddresses.length);
        uint256 canceledCount;

        // Update each benefit member state
        for (uint256 i; i < _benefitAddresses.length; ++i) {
            (, BenefitMember memory benefitMember) = _fetchBenefitMemberFromStorageModule(
                _benefitAddresses[i],
                _memberWallet
            );

            require(
                benefitMember.memberState == BenefitMemberState.Active,
                ModuleErrors.Module__WrongMemberState()
            );

            // Within first year + grace → PendingCancellation (keep it); else → Canceled (remove it)
            if (
                block.timestamp <
                benefitMember.membershipStartTime + ModuleConstants.YEAR + ModuleConstants.MONTH
            ) {
                benefitMember.memberState = BenefitMemberState.PendingCancellation;
            } else {
                benefitMember.memberState = BenefitMemberState.Canceled;
                canceled[canceledCount] = _benefitAddresses[i];
                ++canceledCount;
            }

            protocolStorageModule.updateBenefitMember(_benefitAddresses[i], benefitMember);
            emit TakasureEvents.OnBenefitMemberCanceled(
                benefitMember.memberId,
                _benefitAddresses[i],
                _memberWallet
            );
        }

        if (canceledCount > 0) {
            address[] memory oldBenefits = associationMember.benefits;

            // Filter out any address that appears in `canceled[0..canceledCount)`
            address[] memory temp = new address[](oldBenefits.length);
            uint256 keep;

            for (uint256 i; i < oldBenefits.length; ++i) {
                address old = oldBenefits[i];
                bool remove;

                // small N expected → O(N*M) is fine; short-circuits on match
                for (uint256 j; j < canceledCount; ++j) {
                    if (old == canceled[j]) {
                        remove = true;
                        break;
                    }
                }

                if (!remove) {
                    temp[keep] = old;
                    ++keep;
                }
            }

            // Shrink to exact size
            address[] memory finalBenefits = new address[](keep);
            for (uint256 k; k < keep; ++k) {
                finalBenefits[k] = temp[k];
            }

            associationMember.benefits = finalBenefits;
            protocolStorageModule.updateAssociationMember(associationMember);
        }
    }

    function _fetchAssociationMemberFromStorageModule(
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

    function _fetchBenefitMemberFromStorageModule(
        address _benefit,
        address _userWallet
    )
        internal
        view
        returns (IProtocolStorageModule protocolStorageModule_, BenefitMember memory member_)
    {
        protocolStorageModule_ = IProtocolStorageModule(
            addressManager.getProtocolAddressByName("PROTOCOL_STORAGE_MODULE").addr
        );

        // Get the member from storage
        member_ = protocolStorageModule_.getBenefitMember(_benefit, _userWallet);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(Roles.OPERATOR, address(addressManager)) {}
}
