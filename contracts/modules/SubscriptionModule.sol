//SPDX-License-Identifier: GPL-3.0

/**
 * @title SubscriptionModule
 * @author Maikel Ordaz
 * @notice This contract manage all the subscriptions/refunds to/from the LifeDAO protocol
 * @dev It will interact with the TakasureReserve contract to update the values
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBenefitMultiplierConsumer} from "contracts/interfaces/IBenefitMultiplierConsumer.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {IAddressManager} from "contracts/interfaces/IAddressManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";
import {ReserveAndMemberValuesHook} from "contracts/hooks/ReserveAndMemberValuesHook.sol";
import {MemberPaymentFlow} from "contracts/helpers/payments/MemberPaymentFlow.sol";
import {ParentRewards} from "contracts/helpers/payments/ParentRewards.sol";

import {Reserve, Member, MemberState, ModuleState, ProtocolAddress} from "contracts/types/TakasureTypes.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract SubscriptionModule is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    TLDModuleImplementation,
    ReserveAndMemberValuesHook,
    MemberPaymentFlow,
    ParentRewards
{
    using SafeERC20 for IERC20;

    ITakasureReserve private takasureReserve;
    ModuleState private moduleState;

    uint256 private transient normalizedContributionBeforeFee;
    uint256 private transient feeAmount;
    uint256 private transient contributionAfterFee;
    uint256 private transient discount;

    address private referralGateway;
    address private couponPool;

    // Set to true when new members use coupons to pay their contributions. It does not matter the amount
    mapping(address member => bool) private isMemberCouponRedeemer;

    error SubscriptionModule__InvalidContribution();
    error SubscriptionModule__AlreadyJoined();
    error SubscriptionModule__BenefitMultiplierRequestFailed(bytes errorResponse);
    error SubscriptionModule__MemberAlreadyKYCed();
    error SubscriptionModule__NothingToRefund();
    error SubscriptionModule__TooEarlytoRefund();

    modifier onlyContract(string memory name) {
        require(
            AddressAndStates._checkName(address(takasureReserve.addressManager()), name),
            ModuleErrors.Module__NotAuthorizedCaller()
        );
        _;
    }

    modifier onlyRole(bytes32 role) {
        require(
            AddressAndStates._checkRole(address(takasureReserve.addressManager()), role),
            ModuleErrors.Module__NotAuthorizedCaller()
        );
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _takasureReserveAddress,
        address _referralGateway,
        address _couponPool
    ) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();

        takasureReserve = ITakasureReserve(_takasureReserveAddress);

        referralGateway = _referralGateway;
        couponPool = _couponPool;
    }

    /**
     * @notice Set the module state
     * @dev Only callable from the Module Manager
     */
    function setContractState(
        ModuleState newState
    ) external override onlyContract("MODULE_MANAGER") {
        moduleState = newState;
    }

    function setCouponPoolAddress(address _couponPool) external onlyRole(Roles.OPERATOR) {
        AddressAndStates._notZeroAddress(_couponPool);
        couponPool = _couponPool;
    }

    function joinFromReferralGateway(
        address memberWallet,
        address parentWallet,
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external nonReentrant {
        require(msg.sender == referralGateway, ModuleErrors.Module__NotAuthorizedCaller());

        (
            Reserve memory reserve,
            Member memory newMember,
            uint256 benefitMultiplier
        ) = _paySubscriptionChecksAndsettings(memberWallet, contributionBeforeFee);

        _joinFromReferralGateway(
            reserve,
            newMember,
            memberWallet,
            parentWallet,
            membershipDuration,
            benefitMultiplier
        );
    }

    /**
     * @notice Allow new members to join the pool. All members must pay first, and KYC afterwards. Prejoiners are KYCed by default.
     * @param memberWallet address of the member
     * @param contributionBeforeFee in six decimals
     * @param membershipDuration default 5 years
     * @param parentWallet address of the parent
     * @dev it reverts if the contribution is less than the minimum threshold defaultes to `minimumThreshold`
     * @dev it reverts if the member is already active
     * @dev the contribution amount will be round down so the last four decimals will be zero. This means
     *      that the minimum contribution amount is 0.01 USDC
     * @dev the contribution amount will be round down so the last four decimals will be zero
     */
    function paySubscription(
        address memberWallet,
        address parentWallet,
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external nonReentrant {
        (
            Reserve memory reserve,
            Member memory newMember,
            uint256 benefitMultiplier
        ) = _paySubscriptionChecksAndsettings(memberWallet, contributionBeforeFee);

        // Check caller
        require(
            AddressAndStates._checkName(address(takasureReserve.addressManager()), "ROUTER") ||
                msg.sender == memberWallet,
            ModuleErrors.Module__NotAuthorizedCaller()
        );

        _join(
            reserve,
            newMember,
            memberWallet,
            parentWallet,
            contributionBeforeFee,
            membershipDuration,
            benefitMultiplier,
            0
        );
    }

    /**
     * @notice Called by backend to allow new members to join the pool
     * @param couponAmount in six decimals
     */
    function paySubscriptionOnBehalfOf(
        address memberWallet,
        address parentWallet,
        uint256 contributionBeforeFee,
        uint256 membershipDuration,
        uint256 couponAmount
    ) external nonReentrant onlyRole(Roles.COUPON_REDEEMER) {
        (
            Reserve memory reserve,
            Member memory newMember,
            uint256 benefitMultiplier
        ) = _paySubscriptionChecksAndsettings(memberWallet, contributionBeforeFee);

        // Check if the coupon amount is valid
        require(couponAmount <= contributionBeforeFee, SubscriptionModule__InvalidContribution());

        _join(
            reserve,
            newMember,
            memberWallet,
            parentWallet,
            contributionBeforeFee,
            membershipDuration,
            benefitMultiplier,
            couponAmount
        );

        if (couponAmount > 0) {
            isMemberCouponRedeemer[memberWallet] = true;
            emit TakasureEvents.OnCouponRedeemed(memberWallet, couponAmount);
        }
    }

    function transferContributionAfterKyc(
        IERC20 contributionToken,
        address memberWallet,
        address takasureReserveAddress,
        uint256 contributionAfterFeeAmount
    ) external onlyContract("KYC_MODULE") {
        _transferContributionToReserve(
            contributionToken,
            memberWallet,
            takasureReserveAddress,
            contributionAfterFeeAmount
        );
    }

    /**
     * @notice Method to refunds a user
     * @dev To be called by the user itself
     */
    function refund() external {
        _refund(msg.sender);
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

    function _paySubscriptionChecksAndsettings(
        address _memberWallet,
        uint256 _contributionBeforeFee
    )
        internal
        returns (Reserve memory reserve_, Member memory newMember_, uint256 benefitMultiplier_)
    {
        AddressAndStates._onlyModuleState(moduleState, ModuleState.Enabled);

        (reserve_, newMember_) = _getReserveAndMemberValuesHook(takasureReserve, _memberWallet);

        if (!newMember_.isRefunded) {
            require(newMember_.wallet == address(0), SubscriptionModule__AlreadyJoined());
        } else {
            require(
                newMember_.memberId != 0 && newMember_.wallet == _memberWallet,
                ModuleErrors.Module__WrongMemberState()
            );
        }

        benefitMultiplier_ = _getBenefitMultiplierFromOracle(_memberWallet);

        _calculateAmountAndFees(_contributionBeforeFee, reserve_.serviceFee);
    }

    function _joinFromReferralGateway(
        Reserve memory _reserve,
        Member memory _newMember,
        address _memberWallet,
        address _parentWallet,
        uint256 _membershipDuration,
        uint256 _benefitMultiplier
    ) internal {
        _newMember = _createNewMember({
            _newMemberId: ++_reserve.memberIdCounter,
            _allowCustomDuration: _reserve.allowCustomDuration,
            _drr: _reserve.dynamicReserveRatio,
            _benefitMultiplier: _benefitMultiplier, // Fetch from oracle
            _membershipDuration: _membershipDuration, // From the input
            _isKYCVerified: true, // All members from prejoin are KYCed
            _memberWallet: _memberWallet, // The member wallet
            _parentWallet: _parentWallet, // The parent wallet
            _memberState: MemberState.Active // All members from prejoin are active
        });

        // Then everyting needed will be updated, proformas, reserves, cash flow,
        // DRR, BMA, tokens minted, no need to transfer the amounts as they are already paid
        uint256 mintedTokens;

        (_reserve, mintedTokens) = _memberPaymentFlow({
            _contributionBeforeFee: _newMember.contribution,
            _contributionAfterFee: contributionAfterFee,
            _memberWallet: _memberWallet,
            _reserve: _reserve,
            _takasureReserve: takasureReserve
        });

        _newMember.creditTokensBalance += mintedTokens;

        emit TakasureEvents.OnMemberJoined(_newMember.memberId, _memberWallet);

        _setNewReserveAndMemberValuesHook(takasureReserve, _reserve, _newMember);

        takasureReserve.memberSurplus(_newMember);
    }

    function _join(
        Reserve memory _reserve,
        Member memory _newMember,
        address _memberWallet,
        address _parentWallet,
        uint256 _contributionBeforeFee,
        uint256 _membershipDuration,
        uint256 _benefitMultiplier,
        uint256 _couponAmount
    ) internal {
        require(
            _newMember.memberState == MemberState.Inactive ||
                _newMember.memberState == MemberState.Canceled,
            ModuleErrors.Module__WrongMemberState()
        );
        require(
            _contributionBeforeFee >= _reserve.minimumThreshold &&
                _contributionBeforeFee <= _reserve.maximumThreshold,
            SubscriptionModule__InvalidContribution()
        );

        uint256 memberId;

        if (!_newMember.isRefunded) {
            // Flow 1: Join -> KYC
            memberId = ++_reserve.memberIdCounter;
        } else {
            // Flow 2: Join (with flow 1) -> Refund -> Join
            memberId = _newMember.memberId;
        }

        _newMember = _createNewMember({
            _newMemberId: memberId,
            _allowCustomDuration: _reserve.allowCustomDuration,
            _drr: _reserve.dynamicReserveRatio,
            _benefitMultiplier: _benefitMultiplier, // Fetch from oracle
            _membershipDuration: _membershipDuration, // From the input
            _isKYCVerified: _newMember.isKYCVerified, // The current state, in this case false
            _memberWallet: _memberWallet, // The member wallet
            _parentWallet: _parentWallet, // The parent wallet
            _memberState: MemberState.Inactive // Set to inactive until the KYC is verified
        });

        (_reserve) = _calculateReferralRewards(
            _reserve,
            _couponAmount,
            _memberWallet,
            _parentWallet
        );

        _newMember.discount = discount;

        // The member will pay the contribution, but will remain inactive until the KYC is verified
        // This means the proformas wont be updated, the amounts wont be added to the reserves,
        // the cash flow mappings wont change, the DRR and BMA wont be updated, the tokens wont be minted
        _transferContributionToModule({_memberWallet: _memberWallet, _couponAmount: _couponAmount});
        _setNewReserveAndMemberValuesHook(takasureReserve, _reserve, _newMember);
    }

    function _calculateReferralRewards(
        Reserve memory _reserve,
        uint256 _couponAmount,
        address _child,
        address _parent
    ) internal returns (Reserve memory) {
        uint256 toReferralReserve;

        if (_reserve.referralDiscount) {
            toReferralReserve =
                (normalizedContributionBeforeFee * ModuleConstants.REFERRAL_RESERVE) /
                100;
            if (_parent != address(0)) {
                discount =
                    ((normalizedContributionBeforeFee - _couponAmount) *
                        ModuleConstants.REFERRAL_DISCOUNT_RATIO) /
                    100;
                childToParent[_child] = _parent;
                (feeAmount, _reserve.referralReserve) = _parentRewards({
                    _initialChildToCheck: _child,
                    _contribution: normalizedContributionBeforeFee,
                    _currentReferralReserve: _reserve.referralReserve,
                    _toReferralReserve: toReferralReserve,
                    _currentFee: feeAmount
                });
            } else {
                _reserve.referralReserve += toReferralReserve;
            }
        }
        return (_reserve);
    }

    /**
     * @notice All refunds for users that used coupons will be restored in the coupon pool
     *         The user will need to reach custommer support to get the corresponding amount
     */
    function _refund(address _memberWallet) internal {
        AddressAndStates._onlyModuleState(moduleState, ModuleState.Enabled);

        (Reserve memory _reserve, Member memory _member) = _getReserveAndMemberValuesHook(
            takasureReserve,
            _memberWallet
        );

        address addressManager = address(takasureReserve.addressManager());

        require(
            _memberWallet == msg.sender ||
                AddressAndStates._checkName(addressManager, "ROUTER") ||
                AddressAndStates._checkRole(addressManager, Roles.OPERATOR),
            ModuleErrors.Module__NotAuthorizedCaller()
        );
        // The member should not be KYCed neither already refunded
        require(!_member.isRefunded, SubscriptionModule__NothingToRefund());

        uint256 currentTimestamp = block.timestamp;
        uint256 membershipStartTime = _member.membershipStartTime;
        // The member can refund after 30 days of the payment
        uint256 limitTimestamp = membershipStartTime + (30 days);

        require(currentTimestamp <= limitTimestamp, SubscriptionModule__TooEarlytoRefund());

        // As there is only one contribution, is easy to calculte with the Member struct values
        uint256 contributionAmountAfterFee = _member.contribution -
            (_member.contribution * _reserve.serviceFee) /
            100;
        uint256 discountAmount = _member.discount;
        uint256 amountToRefund = contributionAmountAfterFee - discountAmount;

        Member memory newMember = Member({
            memberId: _member.memberId,
            benefitMultiplier: 0,
            membershipDuration: 0,
            membershipStartTime: 0,
            lastPaidYearStartDate: 0,
            contribution: 0,
            discount: 0,
            claimAddAmount: 0,
            totalContributions: 0,
            totalServiceFee: 0,
            creditTokensBalance: 0,
            wallet: _memberWallet,
            parent: address(0),
            memberState: MemberState.Inactive,
            memberSurplus: 0,
            isKYCVerified: false,
            isRefunded: true,
            lastEcr: 0,
            lastUcr: 0
        });

        _member = newMember;

        // Transfer the amount to refund
        if (isMemberCouponRedeemer[_memberWallet]) {
            // Reset the coupon redeemer status, this way the member can redeem again
            isMemberCouponRedeemer[_memberWallet] = false;
            // We transfer the coupon amount to the coupon pool
            IERC20(_reserve.contributionToken).safeTransfer(couponPool, amountToRefund);
        } else {
            // We transfer the amount to the member
            IERC20(_reserve.contributionToken).safeTransfer(_memberWallet, amountToRefund);
        }

        emit TakasureEvents.OnRefund(_member.memberId, _memberWallet, amountToRefund);

        _setMembersValuesHook(takasureReserve, _member);
    }

    function _calculateAmountAndFees(uint256 _contributionBeforeFee, uint256 _fee) internal {
        // The minimum we can receive is 0,01 USDC, here we round it. This to prevent rounding errors
        // i.e. contributionAmount = (25.123456 / 1e4) * 1e4 = 25.12USDC
        normalizedContributionBeforeFee =
            (_contributionBeforeFee / ModuleConstants.DECIMAL_REQUIREMENT_PRECISION_USDC) *
            ModuleConstants.DECIMAL_REQUIREMENT_PRECISION_USDC;
        feeAmount = (normalizedContributionBeforeFee * _fee) / 100;
        contributionAfterFee = normalizedContributionBeforeFee - feeAmount;
    }

    function _createNewMember(
        uint256 _newMemberId,
        bool _allowCustomDuration,
        uint256 _drr,
        uint256 _benefitMultiplier,
        uint256 _membershipDuration,
        bool _isKYCVerified,
        address _memberWallet,
        address _parentWallet,
        MemberState _memberState
    ) internal returns (Member memory) {
        uint256 userMembershipDuration;

        if (_allowCustomDuration) {
            userMembershipDuration = _membershipDuration;
        } else {
            userMembershipDuration = ModuleConstants.DEFAULT_MEMBERSHIP_DURATION;
        }

        uint256 claimAddAmount = ((normalizedContributionBeforeFee - feeAmount) * (100 - _drr)) /
            100;

        Member memory newMember = Member({
            memberId: _newMemberId,
            benefitMultiplier: _benefitMultiplier,
            membershipDuration: userMembershipDuration,
            membershipStartTime: block.timestamp,
            lastPaidYearStartDate: block.timestamp,
            contribution: normalizedContributionBeforeFee,
            discount: discount,
            claimAddAmount: claimAddAmount,
            totalContributions: normalizedContributionBeforeFee,
            totalServiceFee: feeAmount,
            creditTokensBalance: 0,
            wallet: _memberWallet,
            parent: _parentWallet,
            memberState: _memberState,
            memberSurplus: 0,
            isKYCVerified: _isKYCVerified,
            isRefunded: false,
            lastEcr: 0,
            lastUcr: 0
        });

        emit TakasureEvents.OnMemberCreated(
            newMember.memberId,
            _memberWallet,
            _benefitMultiplier,
            normalizedContributionBeforeFee,
            feeAmount,
            userMembershipDuration,
            block.timestamp,
            _isKYCVerified
        );

        return newMember;
    }

    function _transferContributionToReserve(
        IERC20 _contributionToken,
        address,
        address _takasureReserve,
        uint256 _contributionAfterFee
    ) internal override {
        // If the caller is the prejoin module, the transfer will be done by the prejoin module
        // to the takasure reserve. Otherwise, the transfer will be done by this contract
        if (msg.sender != referralGateway) {
            _contributionToken.safeTransfer(_takasureReserve, _contributionAfterFee - discount);
        }
    }

    function _getBenefitMultiplierFromOracle(
        address _member
    ) internal returns (uint256 benefitMultiplier_) {
        address bmConsumerAddress = IAddressManager(address(takasureReserve.addressManager()))
            .getProtocolAddressByName("BENEFIT_MULTIPLIER_CONSUMER")
            .addr;
        IBenefitMultiplierConsumer bmConsumer = IBenefitMultiplierConsumer(bmConsumerAddress);

        string memory memberAddressToString = Strings.toHexString(uint256(uint160(_member)), 20);
        // First we check if there is already a request id for this member
        bytes32 requestId = bmConsumer.memberToRequestId(memberAddressToString);

        if (requestId == 0) {
            // If there is no request id, it means the member has no valid BM yet. So we make a new request
            string[] memory args = new string[](1);
            args[0] = memberAddressToString;
            bmConsumer.sendRequest(args);
        } else {
            // If there is a request id, we check if it was successful
            bool successRequest = bmConsumer.idToSuccessRequest(requestId);
            if (successRequest) {
                benefitMultiplier_ = bmConsumer.idToBenefitMultiplier(requestId);
            } else {
                // If failed we get the error and revert with it
                bytes memory errorResponse = bmConsumer.idToErrorResponse(requestId);
                revert SubscriptionModule__BenefitMultiplierRequestFailed(errorResponse);
            }
        }
    }

    function _transferContributionToModule(address _memberWallet, uint256 _couponAmount) internal {
        IERC20 contributionToken = IERC20(takasureReserve.getReserveValues().contributionToken);
        uint256 _amountToTransferFromMember;

        if (_couponAmount > 0) {
            _amountToTransferFromMember = contributionAfterFee - discount - _couponAmount;
        } else {
            _amountToTransferFromMember = contributionAfterFee - discount;
        }

        // Store temporarily the contribution in this contract, this way will be available for refunds
        if (_amountToTransferFromMember > 0) {
            contributionToken.safeTransferFrom(
                _memberWallet,
                address(this),
                _amountToTransferFromMember
            );

            // Transfer the coupon amount to this contract
            if (_couponAmount > 0) {
                contributionToken.safeTransferFrom(couponPool, address(this), _couponAmount);
            }
            // Transfer the service fee to the fee claim address
            contributionToken.safeTransferFrom(
                _memberWallet,
                IAddressManager(address(takasureReserve.addressManager()))
                    .getProtocolAddressByName("FEE_CLAIM_ADDRESS")
                    .addr,
                feeAmount
            );
        }
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(Roles.OPERATOR) {}
}
