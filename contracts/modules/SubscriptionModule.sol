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
import {IProtocolStorageModule} from "contracts/interfaces/modules/IProtocolStorageModule.sol";
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

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    error SubscriptionModule__NothingToRefund();

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
    ) external {
        // Module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled,
            address(this),
            addressManager.getProtocolAddressByName("MODULE_MANAGER").addr
        );
        require(
            couponAmount == 0 || couponAmount == ModuleConstants.ASSOCIATION_SUBSCRIPTION,
            ModuleErrors.Module__InvalidCoupon()
        );

        _paySubscription(userWallet, parentWallet, couponAmount, membershipStartTime);
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
    ) external onlyRole(Roles.BACKEND_ADMIN, address(addressManager)) {
        // Module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled,
            address(this),
            addressManager.getProtocolAddressByName("MODULE_MANAGER").addr
        );
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
    function transferSubscriptionToReserve(
        address memberWallet
    ) external nonReentrant returns (uint256) {
        // Module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled,
            address(this),
            addressManager.getProtocolAddressByName("MODULE_MANAGER").addr
        );
        (, AssociationMember memory member) = _fetchMemberFromStorageModule(memberWallet);

        // Access control restrictions
        bool isBackend = AddressAndStates._checkRole(Roles.BACKEND_ADMIN, address(addressManager));
        RevenueType revenueType;

        if (addressManager.hasType(ProtocolAddressType.Benefit, msg.sender)) {
            // If the caller is a benefit then we consider this as a contribution
            revenueType = RevenueType.Contribution;
        } else if (isBackend) {
            // If the caller is the operator, then we consider this as a donation, and have to be called after the refund period ends
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
        uint256 userDiscount = member.discount;

        if (userDiscount > 0) {
            address feeClaimer = addressManager.getProtocolAddressByName("FEE_CLAIM_ADDRESS").addr;
            contributionToken.safeTransferFrom(feeClaimer, address(this), userDiscount);
        }

        contributionToken.approve(revenueModuleAddress, amountToTransfer);
        revenueModule.depositRevenue(amountToTransfer, revenueType);
        return amountToTransfer;
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
            AddressAndStates._checkRole(Roles.BACKEND_ADMIN, address(addressManager)) ||
                AddressAndStates._checkName("ROUTER", address(addressManager)),
            ModuleErrors.Module__NotAuthorizedCaller()
        );

        (
            IProtocolStorageModule protocolStorageModule,
            AssociationMember memory member
        ) = _fetchMemberFromStorageModule(_userWallet);

        // To know if we are creating a new member or updating an existing one we need to check the wallet and refund state
        bool isRejoin = member.wallet == _userWallet && member.isRefunded;

        // Create the member profile
        member = AssociationMember({
            memberId: isRejoin ? member.memberId : 0, // If is a rejoin, keep the same memberId, else use 0 as placeholder, will be set in storage module
            discount: 0, // Placeholder
            couponAmountRedeemed: _couponAmount, // in six decimals
            associateStartTime: _membershipStartTime,
            wallet: _userWallet,
            parent: _parentWallet,
            memberState: AssociationMemberState.Inactive, // Set to inactive until the KYC is verified
            isRefunded: false,
            isLifeProtected: false, // Placeholder, to be set by the Life module
            isFarewellProtected: false // Placeholder, to be set by the Farewell module
        });

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
        member.discount = discount;

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

        if (isRejoin) protocolStorageModule.updateAssociationMember(member);
        else protocolStorageModule.createAssociationMember(member);
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

    function _transferFee(IERC20 _contributionToken, address _fromAddress, uint256 _fee) internal {
        _contributionToken.safeTransferFrom(
            _fromAddress,
            addressManager.getProtocolAddressByName("FEE_CLAIM_ADDRESS").addr,
            _fee
        );
    }

    /**
     * @notice All refunds for users that used coupons will be restored in the coupon pool
     *         The user will need to reach custommer support to get the corresponding amount
     */
    function _refund(address _memberWallet) internal {
        (
            IProtocolStorageModule _protocolStorageModule,
            AssociationMember memory _member
        ) = _fetchMemberFromStorageModule(_memberWallet);

        // The member should exist and not be refunded
        require(_member.wallet == _memberWallet, ModuleErrors.Module__InvalidAddress());
        require(!_member.isRefunded, SubscriptionModule__NothingToRefund());
        uint256 currentTimestamp = block.timestamp;
        uint256 startTime = _member.associateStartTime;

        // The member can refund before 30 days of the payment
        uint256 limitTimestamp = startTime + (30 days);
        require(currentTimestamp <= limitTimestamp, ModuleErrors.Module__InvalidDate());

        // As there is only one contribution, is easy to calculte with the Member struct values
        uint256 contributionAmountAfterFee = ModuleConstants.ASSOCIATION_SUBSCRIPTION -
            ((ModuleConstants.ASSOCIATION_SUBSCRIPTION *
                ModuleConstants.ASSOCIATION_SUBSCRIPTION_FEE) / 100);
        uint256 discountAmount = _member.discount;
        uint256 amountToRefund = contributionAmountAfterFee - discountAmount;

        IERC20 contributionToken = IERC20(
            addressManager.getProtocolAddressByName("CONTRIBUTION_TOKEN").addr
        );

        // Transfer the amount to refund
        if (_member.couponAmountRedeemed > 0) {
            // We transfer the coupon amount to the coupon pool
            address couponPool = addressManager.getProtocolAddressByName("COUPON_POOL").addr;
            contributionToken.safeTransfer(couponPool, amountToRefund);
        } else {
            // We transfer the amount to the member
            contributionToken.safeTransfer(_memberWallet, amountToRefund);
        }

        _member = AssociationMember({
            memberId: _member.memberId,
            discount: 0, // Reset the discount
            couponAmountRedeemed: 0, // Reset the coupon amount redeemed
            associateStartTime: 0, // Reset the start time
            wallet: _memberWallet,
            parent: address(0), // Reset the parent
            memberState: AssociationMemberState.Inactive, // Set to inactive in case the user already made KYC
            isRefunded: true, // Set the member as refunded
            isLifeProtected: false,
            isFarewellProtected: false
        });

        // Update the user as refunded
        _protocolStorageModule.updateAssociationMember(_member);
        emit TakasureEvents.OnRefund(_member.memberId, _memberWallet, amountToRefund);
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
