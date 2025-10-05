//SPDX-License-Identifier: GPL-3.0

/**
 * @title SubscriptionModule
 * @author Maikel Ordaz
 * @notice This contract manage all the subscriptions/refunds to/from the LifeDAO association
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {IModuleImplementation} from "contracts/interfaces/modules/IModuleImplementation.sol";
import {IReferralRewardsModule} from "contracts/interfaces/modules/IReferralRewardsModule.sol";
import {IKYCModule} from "contracts/interfaces/modules/IKYCModule.sol";
import {IRevenueModule} from "contracts/interfaces/modules/IRevenueModule.sol";

import {ModuleImplementation} from "contracts/modules/moduleUtils/ModuleImplementation.sol";
import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {AssociationMember, AssociationMemberState, ModuleState, ProtocolAddress, ProtocolAddressType, RevenueType} from "contracts/types/TakasureTypes.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract SubscriptionModule is
    ModuleImplementation,
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 private memberIdCounter;

    mapping(address member => AssociationMember) private members;
    // Set to true when new members use coupons to pay their contributions. It does not matter the amount
    mapping(address member => bool) private isMemberCouponSubscriptionRedeemer;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/
    event OnNewAssociationMember(
        uint256 indexed memberId,
        address indexed memberWallet,
        address indexed parentWallet
    );

    error SubscriptionModule__InvalidDate();
    error SubscriptionModule__NothingToRefund();
    error SubscriptionModule__TooLateToRefund();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                         SUBSCRIPTION PAYMENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Called by backend to allow new members to join the pool
     * @notice Allow new members to pay subscriptions. All members must pay first, and KYC afterwards.
     * @param userWallet address of the member
     * @param parentWallet Optional parent address. If there is no parent it must be address(0)
     *                     If a parent is provided, it must be KYCed
     * @param membershipStartTime when the membership starts, in seconds
     * @param couponAmount in six decimals
     */
    function paySubscriptionOnBehalfOf(
        address userWallet,
        address parentWallet,
        uint256 couponAmount,
        uint256 membershipStartTime
    ) external onlyRole(Roles.COUPON_REDEEMER, address(addressManager)) {
        require(
            couponAmount == 0 || couponAmount == ModuleConstants.ASSOCIATION_SUBSCRIPTION,
            ModuleErrors.Module__InvalidCoupon()
        );

        _paySubscription(userWallet, parentWallet, couponAmount, membershipStartTime);

        if (couponAmount > 0) {
            isMemberCouponSubscriptionRedeemer[userWallet] = true;
            emit TakasureEvents.OnCouponRedeemed(userWallet, couponAmount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                REFUNDS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Method to refunds a user
     * @dev To be called by the operator only
     * @param memberWallet address to be refunded
     */
    function refund(
        address memberWallet
    ) external onlyRole(Roles.OPERATOR, address(addressManager)) {
        AddressAndStates._notZeroAddress(memberWallet);
        _refund(memberWallet);
    }

    /*//////////////////////////////////////////////////////////////
                         RESERVE CONTRIBUTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transfer the subscription amount to the reserve
     * @param memberWallet address of the member
     * @dev It will transfer the subscription amount to the reserve, this would be 25USDC
     * @dev If the caller is the backend then the Revenue Type will be donation
     * @dev If the caller is a Benefit Module, then the Revenue Type will be Subscription
     */
    function transferSubscriptionToReserve(address memberWallet) external returns (uint256) {
        // Access control restrictions
        bool isOperator = AddressAndStates._checkRole(Roles.OPERATOR, address(addressManager));
        RevenueType revenueType;

        // Get the Benefit Module address
        address lifeBenefitModuleAddress = addressManager
            .getProtocolAddressByName("LIFE_BENEFIT_MODULE")
            .addr;
        address farewellBenefitModuleAddress = addressManager
            .getProtocolAddressByName("FAREWELL_BENEFIT_MODULE")
            .addr;

        if (msg.sender == lifeBenefitModuleAddress || msg.sender == farewellBenefitModuleAddress) {
            // If the caller is a benefit then we consider this as a contribution
            revenueType = RevenueType.Contribution;
        } else if (isOperator) {
            // If the caller is the operator, then we consider this as a donation
            revenueType = RevenueType.ContributionDonation; // ? waive instead of donation
        } else {
            // Any other caller is not authorized
            revert ModuleErrors.Module__NotAuthorizedCaller();
        }

        // Reward the parents if there is any
        IReferralRewardsModule(
            addressManager.getProtocolAddressByName("REFERRAL_REWARDS_MODULE").addr
        ).rewardParents({child: memberWallet});

        // TODO: Revenue module to be written
        address revenueModuleAddress = addressManager
            .getProtocolAddressByName("REVENUE_MODULE")
            .addr;
        IRevenueModule revenueModule = IRevenueModule(revenueModuleAddress);
        IERC20 contributionToken = IERC20(
            addressManager.getProtocolAddressByName("CONTRIBUTION_TOKEN").addr
        );

        uint256 amountToTransfer = ModuleConstants.ASSOCIATION_SUBSCRIPTION -
            ((ModuleConstants.ASSOCIATION_SUBSCRIPTION *
                ModuleConstants.ASSOCIATION_SUBSCRIPTION_FEE) / 100);
        // Check if the user had any discount
        uint256 userDiscount = members[memberWallet].discount;

        if (userDiscount > 0) {
            address feeClaimer = addressManager.getProtocolAddressByName("FEE_CLAIM_ADDRESS").addr;
            contributionToken.safeTransferFrom(feeClaimer, address(this), userDiscount);
        }

        contributionToken.approve(revenueModuleAddress, amountToTransfer);
        revenueModule.depositRevenue(amountToTransfer, revenueType);
        return amountToTransfer;
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function getAssociationMember(
        address memberWallet
    ) external view returns (AssociationMember memory) {
        return members[memberWallet];
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allow new members to pay subscriptions. All members must pay first, and KYC afterwards. Prejoiners are KYCed by default.
     * @param _userWallet address of the member
     * @param _parentWallet address of the parent
     * @param _couponAmount amount of USDC in six decimals to be used as a coupon
     */
    function _paySubscription(
        address _userWallet,
        address _parentWallet,
        uint256 _couponAmount,
        uint256 _membershipStartTime
    ) internal nonReentrant {
        // Check caller
        require(
            AddressAndStates._checkRole(Roles.COUPON_REDEEMER, address(addressManager)) ||
                AddressAndStates._checkName("ROUTER", address(addressManager)),
            ModuleErrors.Module__NotAuthorizedCaller()
        );

        AssociationMember memory newMember = members[_userWallet];

        _paySubscriptionChecks(newMember, _userWallet, _parentWallet, _membershipStartTime);

        newMember = _createAssociationMember(newMember, _userWallet, _parentWallet);

        // TODO: ReferralRewardsModule to be written
        IReferralRewardsModule referralRewardsModule = IReferralRewardsModule(
            addressManager.getProtocolAddressByName("REFERRAL_REWARDS_MODULE").addr
        );
        (
            uint256 feeAmount,
            uint256 discount,
            uint256 toReferralReserveAmount
        ) = referralRewardsModule.calculateReferralRewards({
                contribution: ModuleConstants.ASSOCIATION_SUBSCRIPTION,
                couponAmount: _couponAmount,
                child: _userWallet,
                parent: _parentWallet,
                feeAmount: (ModuleConstants.ASSOCIATION_SUBSCRIPTION *
                    ModuleConstants.ASSOCIATION_SUBSCRIPTION_FEE) / 100
            });
        newMember.discount = discount;

        // Transfer the contribution amount from the user wallet to this contract
        // Transfer the fee to the fee claim address
        // Transfer the referral reserve amount to the referral rewards module to be distributed later
        _performTransfers({
            _fee: feeAmount,
            _discount: discount,
            _couponAmount: _couponAmount,
            _toReferralReserveAmount: toReferralReserveAmount,
            _userWallet: _userWallet,
            _referralRewardsModule: address(referralRewardsModule)
        });

        // Update the member mapping
        members[_userWallet] = newMember;
    }

    function _paySubscriptionChecks(
        AssociationMember memory _newMember,
        address _userWallet,
        address _parentWallet,
        uint256 _membershipStartTime
    ) internal view {
        // The module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled,
            address(this),
            addressManager.getProtocolAddressByName("MODULE_MANAGER").addr
        );

        // The user state must be inactive or canceled
        require(
            _newMember.memberState == AssociationMemberState.Inactive ||
                _newMember.memberState == AssociationMemberState.Canceled,
            ModuleErrors.Module__WrongMemberState()
        );

        // If the user is not refunded then the wallet must be empty, otherwise it must match the user wallet
        if (!_newMember.isRefunded && _newMember.memberState == AssociationMemberState.Inactive)
            require(_newMember.wallet == address(0), ModuleErrors.Module__AlreadyJoined());
        else
            require(
                _newMember.memberId != 0 && _newMember.wallet == _userWallet,
                ModuleErrors.Module__WrongMemberState()
            );

        // If a parent wallet is provided, it must be KYCed
        if (_parentWallet != address(0)) {
            require(_userWallet != _parentWallet, ModuleErrors.Module__InvalidAddress());
            address kycModule = addressManager.getProtocolAddressByName("KYC_MODULE").addr;
            // Check if the parent is KYCed
            require(
                IKYCModule(kycModule).isKYCed(_parentWallet),
                ModuleErrors.Module__AddressNotKYCed()
            );
        }

        // The membership start time can not be in the future
        require(_membershipStartTime <= block.timestamp, SubscriptionModule__InvalidDate());
    }

    function _createAssociationMember(
        AssociationMember memory _newMember,
        address _userWallet,
        address _parentWallet
    ) internal returns (AssociationMember memory) {
        uint256 memberId;
        if (_newMember.isRefunded || _newMember.memberState == AssociationMemberState.Canceled) {
            // Refunded or canceled member
            memberId = _newMember.memberId;
        } else {
            // Completely new member
            memberId = ++memberIdCounter;
        }

        _newMember = AssociationMember({
            memberId: memberId,
            discount: 0, // Placeholder
            associateStartTime: block.timestamp, // Set the start time to now
            wallet: _userWallet,
            parent: _parentWallet,
            memberState: AssociationMemberState.Inactive, // Set to inactive until the KYC is verified
            isRefunded: false,
            isLifeProtected: false, // Placeholder, to be set by the Life module
            isFarewellProtected: false // Placeholder, to be set by the Farewell module
        });

        emit OnNewAssociationMember(_newMember.memberId, _userWallet, _parentWallet);
        return _newMember;
    }

    /**
     * @dev The subscription amount is fixed at 25 USDC
     */
    function _performTransfers(
        uint256 _fee,
        uint256 _discount,
        uint256 _couponAmount,
        uint256 _toReferralReserveAmount,
        address _userWallet,
        address _referralRewardsModule
    ) internal {
        IERC20 contributionToken = IERC20(
            addressManager.getProtocolAddressByName("CONTRIBUTION_TOKEN").addr
        );

        uint256 contributionAfterFee = ModuleConstants.ASSOCIATION_SUBSCRIPTION - _fee;
        bool transferFromMember = _couponAmount == 0 ? true : false;
        uint256 amountToTransfer;

        if (transferFromMember) {
            amountToTransfer = contributionAfterFee - _discount;
            contributionToken.safeTransferFrom(_userWallet, address(this), amountToTransfer);
            _transferFee(contributionToken, _userWallet, _fee);
        } else {
            amountToTransfer = contributionAfterFee;
            address couponPool = addressManager.getProtocolAddressByName("COUPON_POOL").addr;
            contributionToken.safeTransferFrom(couponPool, address(this), amountToTransfer);
            _transferFee(contributionToken, couponPool, _fee);
        }

        // Transfer the referral reserve amount to the corresponding module
        if (_toReferralReserveAmount > 0)
            contributionToken.safeTransfer(_referralRewardsModule, _toReferralReserveAmount);
    }

    function _transferFee(IERC20 _contributionToken, address _userWallet, uint256 _fee) internal {
        _contributionToken.safeTransferFrom(
            _userWallet,
            addressManager.getProtocolAddressByName("FEE_CLAIM_ADDRESS").addr,
            _fee
        );
    }

    /**
     * @notice All refunds for users that used coupons will be restored in the coupon pool
     *         The user will need to reach custommer support to get the corresponding amount
     */
    function _refund(address _memberWallet) internal {
        // Module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled,
            address(this),
            addressManager.getProtocolAddressByName("MODULE_MANAGER").addr
        );

        AssociationMember memory _member = members[_memberWallet];

        // The member should not be refunded
        require(!_member.isRefunded, SubscriptionModule__NothingToRefund());
        uint256 currentTimestamp = block.timestamp;
        uint256 startTime = _member.associateStartTime;

        // The member can refund before 30 days of the payment
        uint256 limitTimestamp = startTime + (30 days);
        require(currentTimestamp <= limitTimestamp, SubscriptionModule__TooLateToRefund());

        // As there is only one contribution, is easy to calculte with the Member struct values
        uint256 contributionAmountAfterFee = ModuleConstants.ASSOCIATION_SUBSCRIPTION -
            ((ModuleConstants.ASSOCIATION_SUBSCRIPTION *
                ModuleConstants.ASSOCIATION_SUBSCRIPTION_FEE) / 100);
        uint256 discountAmount = _member.discount;
        uint256 amountToRefund = contributionAmountAfterFee - discountAmount;

        _member = AssociationMember({
            memberId: _member.memberId,
            discount: 0, // Reset the discount
            associateStartTime: 0, // Reset the start time
            wallet: _memberWallet,
            parent: address(0), // Reset the parent
            memberState: AssociationMemberState.Inactive, // Set to inactive in case the user already made KYC
            isRefunded: true, // Set the member as refunded
            isLifeProtected: false,
            isFarewellProtected: false
        });

        IERC20 contributionToken = IERC20(
            addressManager.getProtocolAddressByName("CONTRIBUTION_TOKEN").addr
        );

        // Transfer the amount to refund
        if (isMemberCouponSubscriptionRedeemer[_memberWallet]) {
            // Reset the coupon redeemer status, this way the member can redeem again
            isMemberCouponSubscriptionRedeemer[_memberWallet] = false;
            // We transfer the coupon amount to the coupon pool
            address couponPool = addressManager.getProtocolAddressByName("COUPON_POOL").addr;
            contributionToken.safeTransfer(couponPool, amountToRefund);
        } else {
            // We transfer the amount to the member
            contributionToken.safeTransfer(_memberWallet, amountToRefund);
        }

        // Update the member mapping
        members[_memberWallet] = _member;
        emit TakasureEvents.OnRefund(_member.memberId, _memberWallet, amountToRefund);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(Roles.OPERATOR, address(addressManager)) {}
}
