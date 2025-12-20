//SPDX-License-Identifier: GPL-3.0

/**
 * @title SubscriptionManagementModule
 * @author Maikel Ordaz
 * @notice This contract will manage cancelations and recurring payments for the TLD Association and its benefits
 * @dev It will interact with the TakasureReserve and/or SubscriptionModule contract to update the corresponding values
 * @dev All external functions are allowed to be called either by the member or by a backend admin
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {IMainStorageModule} from "contracts/interfaces/modules/IMainStorageModule.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {ModuleImplementation} from "contracts/modules/moduleUtils/ModuleImplementation.sol";
import {MemberPaymentFlow} from "contracts/helpers/payments/MemberPaymentFlow.sol";

import {
    Reserve,
    BenefitMember,
    BenefitMemberState,
    ModuleState,
    AssociationMember,
    AssociationMemberState
} from "contracts/types/TakasureTypes.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract SubscriptionManagementModule is
    ModuleImplementation,
    MemberPaymentFlow,
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable
{
    using SafeERC20 for IERC20;

    // Helper struct to avoid stack too deep errors in the benefit payment function
    struct PayRecurringBenefitParams {
        address memberWallet;
        string[] benefitNames;
        uint256[] benefitCouponAmounts;
    }

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

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

    /**
     * @notice Pay for the recurring subscriptions: Association subscription and/or Benefit subscriptions
     * @param memberWallet The wallet of the member paying for the subscriptions
     * @param associationCouponAmount The coupon amount to use for the association subscription in six decimals (0 if none)
     * @param benefitNames The list of benefit names of the benefits to pay for
     * @param benefitCouponAmounts The list of coupon amounts to use for each benefit in six decimals (0 if none)
     */
    function payRecurringSubscription(
        address memberWallet,
        uint256 associationCouponAmount,
        string[] calldata benefitNames,
        uint256[] calldata benefitCouponAmounts
    ) external nonReentrant {
        // Checks
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled,
            address(this),
            IAddressManager(addressManager).getProtocolAddressByName("PROTOCOL__MODULE_MANAGER").addr
        );
        AddressAndStates._notZeroAddress(memberWallet);

        // Pay for the association subscription
        _payRecurringAssociationSubscription(memberWallet, associationCouponAmount);

        // And for the selected benefit subscriptions
        address[] memory benefitsToCancel;
        benefitsToCancel = _payRecurringBenefitSubscriptions(
            PayRecurringBenefitParams({
                memberWallet: memberWallet, benefitNames: benefitNames, benefitCouponAmounts: benefitCouponAmounts
            })
        );

        // Cancel the benefits that could not be paid if any
        if (benefitsToCancel.length > 0) {
            _cancelBenefitSubscriptionsByAddress(memberWallet, benefitsToCancel);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                CANCELS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Cancel the association subscription for a member
     * @param memberWallet The wallet of the member to cancel the association subscription for
     */
    function cancelAssociationSubscription(address memberWallet) external nonReentrant {
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled,
            address(this),
            IAddressManager(addressManager).getProtocolAddressByName("PROTOCOL__MODULE_MANAGER").addr
        );

        _cancelAssociationSubscription(memberWallet);
    }

    /**
     * @notice Cancel benefit subscriptions for a member
     * @param memberWallet The wallet of the member to cancel benefit subscriptions for
     * @param benefitNames The list of benefit names to cancel subscriptions for
     */
    function cancelBenefitSubscriptions(address memberWallet, string[] calldata benefitNames) external nonReentrant {
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled,
            address(this),
            IAddressManager(addressManager).getProtocolAddressByName("PROTOCOL__MODULE_MANAGER").addr
        );

        _cancelBenefitSubscriptions(memberWallet, benefitNames);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to pay for the recurring association subscription
     */
    function _payRecurringAssociationSubscription(address _memberWallet, uint256 _associationCouponAmount) internal {
        (IMainStorageModule mainStorageModule, AssociationMember memory associationMember) =
            _fetchAssociationMemberFromStorageModule(_memberWallet);

        require(
            _associationCouponAmount >= 0 && _associationCouponAmount <= associationMember.planPrice,
            ModuleErrors.Module__InvalidCoupon()
        );

        // Validate the date, it should be able to pay only if the year has ended and grace period for the next payment is not reached
        if (
            block.timestamp >= associationMember.latestPayment + ModuleConstants.YEAR
                && block.timestamp <= associationMember.latestPayment + ModuleConstants.YEAR + ModuleConstants.MONTH
        ) {
            require(
                associationMember.memberState == AssociationMemberState.Active, ModuleErrors.Module__WrongMemberState()
            );

            uint256 newLatestPayment = associationMember.latestPayment + ModuleConstants.YEAR;

            associationMember.latestPayment = newLatestPayment;

            uint256 fee = (associationMember.planPrice * ModuleConstants.ASSOCIATION_SUBSCRIPTION_FEE) / 100;
            uint256 toTransfer = associationMember.planPrice - fee;

            if (_associationCouponAmount == 0) {
                _performTransfers(_memberWallet, _memberWallet, toTransfer, fee);
            } else {
                _performTransfers(
                    _memberWallet, addressManager.getProtocolAddressByName("ADMIN__COUPON_POOL").addr, toTransfer, fee
                );
            }

            mainStorageModule.updateAssociationMember(associationMember);

            emit TakasureEvents.OnRecurringAssociationPayment(
                _memberWallet, associationMember.memberId, associationMember.planPrice
            );
        } else if (block.timestamp > associationMember.latestPayment + ModuleConstants.YEAR + ModuleConstants.MONTH) {
            _cancelAssociationSubscription(_memberWallet);
        } else {
            revert ModuleErrors.Module__InvalidDate();
        }
    }

    /**
     * @notice Internal function to pay for the recurring benefit subscriptions
     * @return benefitsToCancel_ The list of benefit addresses that has to canceled due to non-payment
     */
    function _payRecurringBenefitSubscriptions(PayRecurringBenefitParams memory _params)
        internal
        returns (address[] memory benefitsToCancel_)
    {
        require(_params.benefitNames.length == _params.benefitCouponAmounts.length, ModuleErrors.Module__InvalidInput());

        address[] memory benefitsToPay = new address[](_params.benefitNames.length);

        (benefitsToPay, benefitsToCancel_) = _validateBenefits(_params.memberWallet, _params.benefitNames);

        // Now we loop through all the benefits to pay
        for (uint256 i; i < benefitsToPay.length; ++i) {
            // The coupon must be within the allowed values
            if (_params.benefitCouponAmounts[i] > 0) {
                require(
                    _params.benefitCouponAmounts[i] >= ModuleConstants.BENEFIT_MIN_SUBSCRIPTION
                        && _params.benefitCouponAmounts[i] <= ModuleConstants.BENEFIT_MAX_SUBSCRIPTION,
                    ModuleErrors.Module__InvalidCoupon()
                );
            }

            (IMainStorageModule mainStorageModule, BenefitMember memory benefitMember) =
                _fetchBenefitMemberFromStorageModule(benefitsToPay[i], _params.memberWallet);

            (, AssociationMember memory associationMember) =
                _fetchAssociationMemberFromStorageModule(_params.memberWallet);

            if (_validateDateAndState(benefitMember)) {
                uint256 benefitFee = mainStorageModule.getUintValue("benefitFee");
                uint256 toTransfer;
                uint256 fee;

                if (addressManager.getProtocolAddressByName("BENEFIT__LIFE").addr == benefitsToPay[i]) {
                    // If this is the life benefit, then the amount to pay is reduced by the association recurring payment
                    fee = ((benefitMember.contribution - associationMember.planPrice) * benefitFee) / 100;
                    toTransfer = (benefitMember.contribution - associationMember.planPrice) - fee;
                } else {
                    fee = (benefitMember.contribution * benefitFee) / 100;
                    toTransfer = benefitMember.contribution - fee;
                }

                if (_params.benefitCouponAmounts[i] == 0) {
                    _performTransfers(_params.memberWallet, _params.memberWallet, toTransfer, fee);
                } else {
                    _performTransfers(
                        _params.memberWallet,
                        addressManager.getProtocolAddressByName("ADMIN__COUPON_POOL").addr,
                        toTransfer,
                        fee
                    );
                }

                // todo: check other values after benefit modules are ready
                benefitMember.lastPaidYearStartDate = benefitMember.lastPaidYearStartDate + ModuleConstants.YEAR;
                benefitMember.totalContributions += benefitMember.contribution;
                benefitMember.totalServiceFee += (benefitMember.contribution * benefitFee) / 100;

                mainStorageModule.updateBenefitMember(benefitsToPay[i], benefitMember);
                emit TakasureEvents.OnRecurringBenefitPayment(
                    _params.memberWallet,
                    _params.benefitNames[i],
                    benefitMember.memberId,
                    benefitMember.lastPaidYearStartDate,
                    benefitMember.contribution,
                    benefitMember.totalServiceFee
                );
            } else {
                // If the member is late paying more than the grace period, we set the member to Defaulted
                benefitMember.memberState = BenefitMemberState.Canceled;
                mainStorageModule.updateBenefitMember(benefitsToPay[i], benefitMember);
                emit TakasureEvents.OnBenefitMemberCanceled(
                    benefitMember.memberId, benefitsToPay[i], _params.memberWallet, benefitMember.memberState
                );
            }
        }

        // todo: we'll need to run model algorithms. Do it later when all benefit modules are ready
    }

    /**
     * @notice Internal function to perform the transfers for the contributions and fees
     * @param _userAddress The wallet of the user making the payment
     * @param _from The address from which the funds will be taken (either user wallet or coupon pool)
     * @param _contribution The contribution amount to transfer
     * @param _fee The fee amount to transfer
     * @dev If the _from is the coupon pool, then the caller must be a backend admin
     * @dev If the _from is the user wallet, then the caller must be the user wallet
     */
    function _performTransfers(address _userAddress, address _from, uint256 _contribution, uint256 _fee) internal {
        address couponPoolAddress = addressManager.getProtocolAddressByName("ADMIN__COUPON_POOL").addr;
        address feeClaimer = addressManager.getProtocolAddressByName("ADMIN__FEE_CLAIM_ADDRESS").addr;
        address reserve = addressManager.getProtocolAddressByName("PROTOCOL__TAKASURE_RESERVE").addr;
        IERC20 contributionToken = IERC20(addressManager.getProtocolAddressByName("PROTOCOL__CONTRIBUTION_TOKEN").addr);

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
            IMainStorageModule mainStorageModule =
                IMainStorageModule(addressManager.getProtocolAddressByName("MODULE__MAIN_STORAGE").addr);
            require(
                mainStorageModule.getBoolValue("allowUserInitiatedCalls"), ModuleErrors.Module__NotAuthorizedCaller()
            );
            require(msg.sender == _userAddress, ModuleErrors.Module__NotAuthorizedCaller());

            contributionToken.safeTransferFrom(_userAddress, reserve, _contribution);
            contributionToken.safeTransferFrom(_userAddress, feeClaimer, _fee);
        }
    }

    /**
     * @notice Internal function to validate that the benefits belong to the association member
     * @param _memberWallet The wallet of the association member
     * @param _benefitNames The list of benefit names to validate
     * @dev Reverts if any of the benefit do not belong to the association member
     */
    function _validateBenefits(address _memberWallet, string[] memory _benefitNames)
        internal
        view
        returns (address[] memory benefitAddresses_, address[] memory remainingBenefits_)
    {
        // Get the association member to validate the benefits
        (, AssociationMember memory associationMember) = _fetchAssociationMemberFromStorageModule(_memberWallet);

        address[] memory memberBenefits = associationMember.benefits;

        uint256 namesLen = _benefitNames.length;

        if (namesLen == 0) {
            benefitAddresses_ = new address[](0);
            remainingBenefits_ = memberBenefits;
        } else {
            uint256 memberBenefitsLen = memberBenefits.length;

            // Addresses corresponding to each given benefit name
            benefitAddresses_ = new address[](namesLen);

            // Track which member benefits have been "used" (matched) by the names
            bool[] memory used = new bool[](memberBenefitsLen);

            // Validate that all requested benefits belong to the member
            // O(M * N) with small expected sizes
            for (uint256 i; i < namesLen; ++i) {
                address benefit = addressManager.getProtocolAddressByName(_benefitNames[i]).addr;
                bool found;

                for (uint256 j; j < memberBenefitsLen; ++j) {
                    if (memberBenefits[j] == benefit) {
                        found = true;
                        benefitAddresses_[i] = benefit;
                        used[j] = true; // mark this benefit as consumed
                        break;
                    }
                }

                if (!found) {
                    revert ManageSubscriptionModule__InvalidBenefit();
                }
            }

            // Count how many benefits remain unused
            uint256 remainingCount;
            for (uint256 i; i < memberBenefitsLen; ++i) {
                if (!used[i]) {
                    unchecked {
                        ++remainingCount;
                    }
                }
            }

            // Populate remainingBenefits_ with those unused benefits
            remainingBenefits_ = new address[](remainingCount);
            uint256 k;
            for (uint256 i; i < memberBenefitsLen; ++i) {
                if (!used[i]) {
                    remainingBenefits_[k] = memberBenefits[i];
                    unchecked {
                        ++k;
                    }
                }
            }
        }
    }

    /**
     * @notice Internal function to validate the date and state of a benefit member
     * @param _benefitMember The benefit member to validate
     * @return validated_ Whether the benefit member is valid for payment
     */
    function _validateDateAndState(BenefitMember memory _benefitMember) internal view returns (bool validated_) {
        require(_benefitMember.memberState == BenefitMemberState.Active, ModuleErrors.Module__WrongMemberState());

        // Validate the date, it should be able to pay only if the year has ended and grace period for the next payment is not reached
        if (
            block.timestamp >= _benefitMember.lastPaidYearStartDate + ModuleConstants.YEAR
                && block.timestamp
                    <= _benefitMember.lastPaidYearStartDate + ModuleConstants.YEAR + ModuleConstants.MONTH
        ) validated_ = true;
    }

    function _cancelAssociationSubscription(address _memberWallet) internal {
        (IMainStorageModule mainStorageModule, AssociationMember memory associationMember) =
            _fetchAssociationMemberFromStorageModule(_memberWallet);

        require(associationMember.memberState == AssociationMemberState.Active, ModuleErrors.Module__WrongMemberState());

        if (block.timestamp < associationMember.associateStartTime + ModuleConstants.YEAR + ModuleConstants.MONTH) {
            associationMember.memberState = AssociationMemberState.PendingCancelation;
        } else {
            associationMember = AssociationMember({
                memberId: associationMember.memberId,
                planPrice: 0, // Reset the plan price
                discount: 0, // Reset the discount
                couponAmountRedeemed: 0, // Reset the coupon redeemed
                associateStartTime: 0, // Reset the start time
                latestPayment: 0, // Reset the latest payment timestamp
                wallet: _memberWallet,
                parent: address(0), // Reset the parent
                memberState: AssociationMemberState.Canceled,
                isRefunded: false,
                benefits: associationMember.benefits,
                childs: new address[](0)
            });
        }

        // Cancel all the benefit subscriptions
        _cancelBenefitSubscriptionsByAddress(_memberWallet, associationMember.benefits);

        mainStorageModule.updateAssociationMember(associationMember);

        emit TakasureEvents.OnAssociationMemberCanceled(
            associationMember.memberId, _memberWallet, associationMember.memberState
        );
    }

    function _cancelBenefitSubscriptions(address _memberWallet, string[] memory _benefitNames) internal {
        address[] memory benefitToCancel = new address[](_benefitNames.length);
        // Validate the benefits
        (benefitToCancel,) = _validateBenefits(_memberWallet, _benefitNames);

        _cancelBenefitSubscriptionsByAddress(_memberWallet, benefitToCancel);
    }

    function _cancelBenefitSubscriptionsByAddress(address _memberWallet, address[] memory _benefitAddresses) internal {
        (IMainStorageModule mainStorageModule,) = _fetchAssociationMemberFromStorageModule(_memberWallet);

        // Track the benefits that actually become CANCELED (only these are removed)
        address[] memory canceled = new address[](_benefitAddresses.length);
        uint256 canceledCount;

        // Update each benefit member state
        for (uint256 i; i < _benefitAddresses.length; ++i) {
            (, BenefitMember memory benefitMember) =
                _fetchBenefitMemberFromStorageModule(_benefitAddresses[i], _memberWallet);

            require(benefitMember.memberState == BenefitMemberState.Active, ModuleErrors.Module__WrongMemberState());

            // Within first year + grace → PendingCancelation (keep it); else → Canceled (remove it)
            if (block.timestamp < benefitMember.membershipStartTime + ModuleConstants.YEAR + ModuleConstants.MONTH) {
                benefitMember.memberState = BenefitMemberState.PendingCancelation;
            } else {
                benefitMember.memberState = BenefitMemberState.Canceled;
                canceled[canceledCount] = _benefitAddresses[i];
                ++canceledCount;
            }

            mainStorageModule.updateBenefitMember(_benefitAddresses[i], benefitMember);
            emit TakasureEvents.OnBenefitMemberCanceled(
                benefitMember.memberId, _benefitAddresses[i], _memberWallet, benefitMember.memberState
            );
        }
    }

    function _fetchAssociationMemberFromStorageModule(address _userWallet)
        internal
        view
        returns (IMainStorageModule mainStorageModule_, AssociationMember memory member_)
    {
        mainStorageModule_ = IMainStorageModule(addressManager.getProtocolAddressByName("MODULE__MAIN_STORAGE").addr);

        // Get the member from storage
        member_ = mainStorageModule_.getAssociationMember(_userWallet);
    }

    function _fetchBenefitMemberFromStorageModule(address _benefit, address _userWallet)
        internal
        view
        returns (IMainStorageModule mainStorageModule_, BenefitMember memory member_)
    {
        mainStorageModule_ = IMainStorageModule(addressManager.getProtocolAddressByName("MODULE__MAIN_STORAGE").addr);

        // Get the member from storage
        member_ = mainStorageModule_.getBenefitMember(_benefit, _userWallet);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(Roles.OPERATOR, address(addressManager))
    {}
}
