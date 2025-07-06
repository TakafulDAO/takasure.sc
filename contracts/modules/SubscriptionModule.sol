//SPDX-License-Identifier: GPL-3.0

/**
 * @title SubscriptionModule
 * @author Maikel Ordaz
 * @notice This contract manage all the subscriptions/refunds to/from the LifeDAO protocol
 * @dev It will interact with the TakasureReserve contract to update the values
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ITLDModuleImplementation} from "contracts/interfaces/modules/ITLDModuleImplementation.sol";
import {IReferralRewardsModule} from "contracts/interfaces/modules/IReferralRewardsModule.sol";
import {IKYCModule} from "contracts/interfaces/modules/IKYCModule.sol";
import {IRevenueModule} from "contracts/interfaces/modules/IRevenueModule.sol";

import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";
import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {AssociationMember, AssociationMemberState, ModuleState, ProtocolAddress, ProtocolAddressType, RevenueType} from "contracts/types/TakasureTypes.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract SubscriptionModule is
    TLDModuleImplementation,
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 private memberIdCounter;

    address private couponPool;

    // Set to true when new members use coupons to pay their contributions. It does not matter the amount
    mapping(address member => AssociationMember) private members;
    mapping(address member => bool) private isMemberCouponRedeemer;

    uint256 private constant SUBSCRIPTION_AMOUNT = 25e6; // 25 USDC in six decimals
    uint256 private constant FEE = 27; // 27% service fee, in percentage

    event OnNewAssociationMember(
        uint256 indexed memberId,
        address indexed memberWallet,
        address indexed parentWallet
    );

    error SubscriptionModule__InvalidCoupon();
    error SubscriptionModule__AlreadyJoined();
    error SubscriptionModule__InvalidDate();
    error SubscriptionModule__NothingToRefund();
    error SubscriptionModule__TooEarlytoRefund();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _addressManager,
        address _couponPool,
        string calldata _moduleName
    ) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();

        addressManager = IAddressManager(_addressManager);
        couponPool = _couponPool;
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

    function setCouponPoolAddress(
        address _couponPool
    ) external onlyRole(Roles.OPERATOR, address(addressManager)) {
        AddressAndStates._notZeroAddress(_couponPool);
        couponPool = _couponPool;
    }

    /**
     * @notice Called by backend to allow new members to join the pool
     * @notice Allow new members to pay subscriptions. All members must pay first, and KYC afterwards.
     * @param userWallet address of the member
     * @param parentWallet address of the parent
     * @param membershipStartTime when the membership starts, in seconds
     * @param couponAmount in six decimals
     */
    function paySubscriptionOnBehalfOf(
        address userWallet,
        address parentWallet,
        uint256 couponAmount,
        uint256 membershipStartTime
    ) external onlyRole(Roles.COUPON_REDEEMER, address(addressManager)) {
        require(couponAmount == SUBSCRIPTION_AMOUNT, SubscriptionModule__InvalidCoupon());

        _paySubscription(userWallet, parentWallet, couponAmount, membershipStartTime);

        isMemberCouponRedeemer[userWallet] = true;
        emit TakasureEvents.OnCouponRedeemed(userWallet, couponAmount);
    }

    /**
     * @notice Method to refunds a user
     * @dev To be called by anyone
     * @param memberWallet address to be refunded
     */
    function refund(address memberWallet) external {
        AddressAndStates._notZeroAddress(memberWallet);
        _refund(memberWallet);
    }

    // TODO: Access control should be implemented
    function transferDonationsToReserve(uint256 amount) external {
        address revenueModuleAddress = addressManager
            .getProtocolAddressByName("REVENUE_MODULE")
            .addr;
        IRevenueModule revenueModule = IRevenueModule(revenueModuleAddress);

        revenueModule.depositRevenue(amount, RevenueType.CatDonation);
    }

    function modifyAssociationMember(AssociationMember memory member) external {
        // Only an address of type MODULE can modify association members
        string memory callerModuleName = ITLDModuleImplementation(msg.sender).moduleName();
        require(
            addressManager.getProtocolAddressByName(callerModuleName).addressType ==
                ProtocolAddressType.Module,
            ModuleErrors.Module__NotAuthorizedCaller()
        );

        members[member.wallet] = member;
    }

    function getMember(address memberWallet) external view returns (AssociationMember memory) {
        return members[memberWallet];
    }

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
            AddressAndStates._checkName(address(addressManager), "ROUTER") ||
                msg.sender == _userWallet,
            ModuleErrors.Module__NotAuthorizedCaller()
        );

        AssociationMember memory newMember = members[_userWallet];

        _paySubscriptionChecks(newMember, _userWallet, _parentWallet, _membershipStartTime);

        newMember = _createAssociationMember(newMember, _userWallet, _parentWallet);

        (uint256 feeAmount, uint256 discount) = IReferralRewardsModule(
            addressManager.getProtocolAddressByName("REFERRAL_REWARDS_MODULE").addr
        ).calculateReferralRewardsFromSubscriptions(
                SUBSCRIPTION_AMOUNT,
                _couponAmount,
                _userWallet,
                _parentWallet,
                (SUBSCRIPTION_AMOUNT * FEE) / 100
            );

        newMember.discount = discount;

        IERC20 contributionToken = IERC20(
            addressManager.getProtocolAddressByName("CONTRIBUTION_TOKEN").addr
        );

        // Transfer the contribution amount from the user wallet to this contract
        _transferSubscriptionToModule({
            _contributionToken: contributionToken,
            _fee: feeAmount,
            _discount: discount,
            _couponAmount: _couponAmount,
            _userWallet: _userWallet
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
        AddressAndStates._onlyModuleState(moduleState, ModuleState.Enabled);

        // The user state must be inactive or canceled
        require(
            _newMember.memberState == AssociationMemberState.Inactive ||
                _newMember.memberState == AssociationMemberState.Canceled,
            ModuleErrors.Module__WrongMemberState()
        );

        // If the user is not refunded then the wallet must be empty, otherwise it must match the user wallet
        if (!_newMember.isRefunded)
            require(_newMember.wallet == address(0), SubscriptionModule__AlreadyJoined());
        else
            require(
                _newMember.memberId != 0 && _newMember.wallet == _userWallet,
                ModuleErrors.Module__WrongMemberState()
            );

        // If a parent wallet is provided, it must be KYCed
        if (_parentWallet != address(0)) {
            address kycModule = addressManager.getProtocolAddressByName("KYC_MODULE").addr;

            // Check if the parent is KYCed
            require(
                IKYCModule(kycModule).isKYCed(_parentWallet),
                ModuleErrors.Module__ParentNotKYCed()
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

        if (!_newMember.isRefunded) {
            // Flow 1: Join -> KYC
            memberId = ++memberIdCounter;
        } else {
            // Flow 2: Join (with flow 1) -> Refund -> Join
            memberId = _newMember.memberId;
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
    function _transferSubscriptionToModule(
        IERC20 _contributionToken,
        uint256 _fee,
        uint256 _discount,
        uint256 _couponAmount,
        address _userWallet
    ) internal {
        uint256 contributionAfterFee = SUBSCRIPTION_AMOUNT - _fee;

        uint256 amountToTransferFromMember;

        if (_couponAmount > 0) {
            amountToTransferFromMember = contributionAfterFee - _discount - _couponAmount;
        } else {
            amountToTransferFromMember = contributionAfterFee - _discount;
        }

        if (amountToTransferFromMember > 0) {
            _contributionToken.safeTransferFrom(
                _userWallet,
                address(this),
                amountToTransferFromMember
            );

            // Transfer the coupon amount to this contract
            if (_couponAmount > 0) {
                _contributionToken.safeTransferFrom(couponPool, address(this), _couponAmount);
            }

            // Transfer the service fee to the fee claim address
            _transferFee(_contributionToken, _userWallet, _fee);
        }
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
        AddressAndStates._onlyModuleState(moduleState, ModuleState.Enabled);

        AssociationMember memory _member = members[_memberWallet];
        require(
            AddressAndStates._checkRole(address(addressManager), Roles.OPERATOR),
            ModuleErrors.Module__NotAuthorizedCaller()
        );

        // The member should not be refunded
        require(!_member.isRefunded, SubscriptionModule__NothingToRefund());
        uint256 currentTimestamp = block.timestamp;
        uint256 startTime = _member.associateStartTime;
        // The member can refund before 30 days of the payment
        uint256 limitTimestamp = startTime + (30 days);
        require(currentTimestamp <= limitTimestamp, SubscriptionModule__TooEarlytoRefund());
        // As there is only one contribution, is easy to calculte with the Member struct values
        uint256 contributionAmountAfterFee = SUBSCRIPTION_AMOUNT -
            ((SUBSCRIPTION_AMOUNT * FEE) / 100);
        uint256 discountAmount = _member.discount;
        uint256 amountToRefund = contributionAmountAfterFee - discountAmount;

        _member = AssociationMember({
            memberId: _member.memberId,
            discount: 0, // Reset the discount
            associateStartTime: 0, // Reset the start time
            wallet: _memberWallet,
            parent: address(0), // Reset the parent
            memberState: AssociationMemberState.Inactive, // Set to inactive
            isRefunded: true, // Set the member as refunded
            isLifeProtected: false,
            isFarewellProtected: false
        });

        IERC20 contributionToken = IERC20(
            addressManager.getProtocolAddressByName("CONTRIBUTION_TOKEN").addr
        );

        // Transfer the amount to refund
        if (isMemberCouponRedeemer[_memberWallet]) {
            // Reset the coupon redeemer status, this way the member can redeem again
            isMemberCouponRedeemer[_memberWallet] = false;
            // We transfer the coupon amount to the coupon pool
            contributionToken.safeTransfer(couponPool, amountToRefund);
        } else {
            // We transfer the amount to the member
            contributionToken.safeTransfer(_memberWallet, amountToRefund);
        }

        emit TakasureEvents.OnRefund(_member.memberId, _memberWallet, amountToRefund);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(Roles.OPERATOR, address(addressManager)) {}
}
