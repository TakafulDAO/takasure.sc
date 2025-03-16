//SPDX-License-Identifier: GPL-3.0

/**
 * @title EntryModule
 * @author Maikel Ordaz
 * @notice This contract manage all the process to become a member
 * @dev Important notes:
 *      1. Prejoiners must join from the prejoin module
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBenefitMultiplierConsumer} from "contracts/interfaces/IBenefitMultiplierConsumer.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {ITSToken} from "contracts/interfaces/ITSToken.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";
import {ReserveAndMemberValuesHook} from "contracts/hooks/ReserveAndMemberValuesHook.sol";
import {MemberPaymentFlow} from "contracts/helpers/payments/MemberPaymentFlow.sol";
import {ParentRewards} from "contracts/helpers/payments/ParentRewards.sol";

import {Reserve, Member, MemberState, CashFlowVars, ModuleState} from "contracts/types/TakasureTypes.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";
import {ReserveMathAlgorithms} from "contracts/helpers/libraries/algorithms/ReserveMathAlgorithms.sol";
import {CashFlowAlgorithms} from "contracts/helpers/libraries/algorithms/CashFlowAlgorithms.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract EntryModule is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    TLDModuleImplementation,
    ReserveAndMemberValuesHook,
    MemberPaymentFlow,
    ParentRewards
{
    using SafeERC20 for IERC20;

    ITakasureReserve private takasureReserve;
    IBenefitMultiplierConsumer private bmConsumer;
    ModuleState private moduleState;

    uint256 private transient normalizedContributionBeforeFee;
    uint256 private transient feeAmount;
    uint256 private transient contributionAfterFee;
    uint256 private transient discount;
    address private prejoinModule;
    address private couponPool;
    address private ccipReceiverContract;

    mapping(address child => address parent) public childToParent;
    mapping(address parent => mapping(address child => uint256 reward)) public parentRewardsByChild;
    mapping(address parent => mapping(uint256 layer => uint256 reward)) public parentRewardsByLayer;

    uint256 private constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution deducted from contribution
    uint256 private constant REFERRAL_RESERVE = 5; // 5% of contribution to Referral Reserve

    error EntryModule__NoContribution();
    error EntryModule__ContributionOutOfRange();
    error EntryModule__AlreadyJoinedPendingForKYC();
    error EntryModule__BenefitMultiplierRequestFailed(bytes errorResponse);
    error EntryModule__MemberAlreadyKYCed();
    error EntryModule__NothingToRefund();
    error EntryModule__TooEarlytoRefund();
    error EntryModule__NotAuthorizedCaller();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _takasureReserveAddress,
        address _prejoinModule,
        address _ccipReceiverContract,
        address _couponPool
    ) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuardTransient_init();

        takasureReserve = ITakasureReserve(_takasureReserveAddress);
        bmConsumer = IBenefitMultiplierConsumer(takasureReserve.bmConsumer());
        address takadaoOperator = takasureReserve.takadaoOperator();
        address moduleManager = takasureReserve.moduleManager();
        prejoinModule = _prejoinModule;
        ccipReceiverContract = _ccipReceiverContract;
        couponPool = _couponPool;

        _grantRole(DEFAULT_ADMIN_ROLE, takadaoOperator);
        _grantRole(ModuleConstants.MODULE_MANAGER, moduleManager);
        _grantRole(ModuleConstants.TAKADAO_OPERATOR, takadaoOperator);
        _grantRole(ModuleConstants.KYC_PROVIDER, takasureReserve.kycProvider());
    }

    /**
     * @notice Set the module state
     * @dev Only callable from the Module Manager
     */
    function setContractState(
        ModuleState newState
    ) external override onlyRole(ModuleConstants.MODULE_MANAGER) {
        moduleState = newState;
    }

    function setCouponPoolAddress(
        address _couponPool
    ) external onlyRole(ModuleConstants.TAKADAO_OPERATOR) {
        AddressAndStates._notZeroAddress(_couponPool);
        couponPool = _couponPool;
    }

    function setCCIPReceiverContract(
        address _ccipReceiverContract
    ) external onlyRole(ModuleConstants.TAKADAO_OPERATOR) {
        AddressAndStates._notZeroAddress(_ccipReceiverContract);
        ccipReceiverContract = _ccipReceiverContract;
    }

    /**
     * @notice Allow new members to join the pool. If the member is not KYCed, it will be created as inactive
     *         until the KYC is verified.If the member is already KYCed, the contribution will be paid and the
     *         member will be active.
     * @param membersWallet address of the member
     * @param contributionBeforeFee in six decimals
     * @param membershipDuration default 5 years
     * @param parentWallet address of the parent
     * @dev it reverts if the contribution is less than the minimum threshold defaultes to `minimumThreshold`
     * @dev it reverts if the member is already active
     * @dev the contribution amount will be round down so the last four decimals will be zero. This means
     *      that the minimum contribution amount is 0.01 USDC
     * @dev the contribution amount will be round down so the last four decimals will be zero
     */
    function joinPool(
        address membersWallet,
        address parentWallet,
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external nonReentrant {
        AddressAndStates._onlyModuleState(moduleState, ModuleState.Enabled);
        (Reserve memory reserve, Member memory newMember) = _getReserveAndMemberValuesHook(
            takasureReserve,
            membersWallet
        );

        uint256 benefitMultiplier = _getBenefitMultiplierFromOracle(membersWallet);

        _calculateAmountAndFees(contributionBeforeFee, reserve.serviceFee);

        if (msg.sender == prejoinModule) {
            _joinFromPrejoinModule(
                reserve,
                newMember,
                membersWallet,
                parentWallet,
                membershipDuration,
                benefitMultiplier
            );
        } else {
            _join(
                reserve,
                newMember,
                membersWallet,
                parentWallet,
                contributionBeforeFee,
                membershipDuration,
                benefitMultiplier,
                0
            );
        }
    }

    /**
     * @notice Called by backend or CCIP protocol to allow new members to join the pool
     * @param couponAmount in six decimals
     */
    function joinPoolOnBehalfOf(
        address membersWallet,
        address parentWallet,
        uint256 contributionBeforeFee,
        uint256 membershipDuration,
        uint256 couponAmount
    ) external nonReentrant {
        AddressAndStates._onlyModuleState(moduleState, ModuleState.Enabled);
        _onlyCouponRedeemerOrCcipReceiver;

        (Reserve memory reserve, Member memory newMember) = _getReserveAndMemberValuesHook(
            takasureReserve,
            membersWallet
        );

        uint256 benefitMultiplier = _getBenefitMultiplierFromOracle(membersWallet);

        _calculateAmountAndFees(contributionBeforeFee, reserve.serviceFee);

        _join(
            reserve,
            newMember,
            membersWallet,
            parentWallet,
            contributionBeforeFee,
            membershipDuration,
            benefitMultiplier,
            couponAmount
        );

        if (couponAmount > 0) emit TakasureEvents.OnCouponRedeemed(membersWallet, couponAmount);
    }

    /**
     * @notice Set the KYC status of a member. If the member does not exist, it will be created as inactive
     *         until the contribution is paid with joinPool. If the member has already joined the pool, then
     *         the contribution will be paid and the member will be active.
     * @param memberWallet address of the member
     * @dev It reverts if the member is the zero address
     * @dev It reverts if the member is already KYCed
     */
    function setKYCStatus(address memberWallet) external onlyRole(ModuleConstants.KYC_PROVIDER) {
        AddressAndStates._onlyModuleState(moduleState, ModuleState.Enabled);
        AddressAndStates._notZeroAddress(memberWallet);
        (Reserve memory reserve, Member memory newMember) = _getReserveAndMemberValuesHook(
            takasureReserve,
            memberWallet
        );

        require(!newMember.isKYCVerified, EntryModule__MemberAlreadyKYCed());
        require(newMember.contribution > 0, EntryModule__NoContribution());

        // This means the user exists and payed contribution but is not KYCed yet, we update the values
        _calculateAmountAndFees(newMember.contribution, reserve.serviceFee);

        uint256 benefitMultiplier = _getBenefitMultiplierFromOracle(memberWallet);

        newMember = _updateMember({
            _drr: reserve.dynamicReserveRatio, // We take the current value
            _benefitMultiplier: benefitMultiplier, // We take the current value
            _membershipDuration: newMember.membershipDuration, // We take the current value
            _memberWallet: memberWallet, // The member wallet
            _memberState: MemberState.Active, // Active state as the user is already paid the contribution and KYCed
            _isKYCVerified: true, // Set to true with this call
            _isRefunded: false, // Remains false as the user is not refunded
            _allowCustomDuration: reserve.allowCustomDuration,
            _member: newMember
        });

        // Then the everyting needed will be updated, proformas, reserves, cash flow,
        // DRR, BMA, tokens minted, no need to transfer the amounts as they are already paid
        uint256 mintedTokens;

        (reserve, mintedTokens) = _memberPaymentFlow({
            _contributionBeforeFee: newMember.contribution,
            _contributionAfterFee: contributionAfterFee,
            _memberWallet: memberWallet,
            _reserve: reserve,
            _takasureReserve: takasureReserve
        });

        newMember.creditTokensBalance += mintedTokens;

        // Reward the parents
        address parent = childToParent[memberWallet];

        for (uint256 i; i < uint256(MAX_TIER); ++i) {
            if (parent == address(0)) break;

            uint256 layer = i + 1;

            uint256 parentReward = parentRewardsByChild[parent][memberWallet];

            // Reset the rewards for this child
            parentRewardsByChild[parent][memberWallet] = 0;

            IERC20(reserve.contributionToken).safeTransfer(parent, parentReward);

            emit TakasureEvents.OnParentRewarded(parent, layer, memberWallet, parentReward);

            // We update the parent address to check the next parent
            parent = childToParent[parent];
        }

        emit TakasureEvents.OnMemberKycVerified(newMember.memberId, memberWallet);
        emit TakasureEvents.OnMemberJoined(newMember.memberId, memberWallet);

        _setNewReserveAndMemberValuesHook(takasureReserve, reserve, newMember);
        takasureReserve.memberSurplus(newMember);
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

    function updateBmAddress() external onlyRole(ModuleConstants.TAKADAO_OPERATOR) {
        bmConsumer = IBenefitMultiplierConsumer(takasureReserve.bmConsumer());
    }

    function _joinFromPrejoinModule(
        Reserve memory _reserve,
        Member memory _newMember,
        address _membersWallet,
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
            _memberWallet: _membersWallet, // The member wallet
            _parentWallet: _parentWallet, // The parent wallet
            _memberState: MemberState.Active // Set to inactive until the KYC is verified
        });

        // Then the everyting needed will be updated, proformas, reserves, cash flow,
        // DRR, BMA, tokens minted, no need to transfer the amounts as they are already paid
        uint256 mintedTokens;

        (_reserve, mintedTokens) = _memberPaymentFlow({
            _contributionBeforeFee: _newMember.contribution,
            _contributionAfterFee: contributionAfterFee,
            _memberWallet: _membersWallet,
            _reserve: _reserve,
            _takasureReserve: takasureReserve
        });

        _newMember.creditTokensBalance += mintedTokens;

        emit TakasureEvents.OnMemberJoined(_newMember.memberId, _membersWallet);

        _setNewReserveAndMemberValuesHook(takasureReserve, _reserve, _newMember);
        takasureReserve.memberSurplus(_newMember);
    }

    function _join(
        Reserve memory _reserve,
        Member memory _newMember,
        address _membersWallet,
        address _parentWallet,
        uint256 _contributionBeforeFee,
        uint256 _membershipDuration,
        uint256 _benefitMultiplier,
        uint256 _couponAmount
    ) internal {
        require(
            _newMember.memberState == MemberState.Inactive,
            ModuleErrors.Module__WrongMemberState()
        );
        require(
            _contributionBeforeFee >= _reserve.minimumThreshold &&
                _contributionBeforeFee <= _reserve.maximumThreshold,
            EntryModule__ContributionOutOfRange()
        );

        if (!_newMember.isRefunded) {
            // Flow 1: Join -> KYC
            require(_newMember.wallet == address(0), EntryModule__AlreadyJoinedPendingForKYC());
            // If is not refunded, it is a completele new member, we create it
            _newMember = _createNewMember({
                _newMemberId: ++_reserve.memberIdCounter,
                _allowCustomDuration: _reserve.allowCustomDuration,
                _drr: _reserve.dynamicReserveRatio,
                _benefitMultiplier: _benefitMultiplier, // Fetch from oracle
                _membershipDuration: _membershipDuration, // From the input
                _isKYCVerified: _newMember.isKYCVerified, // The current state, in this case false
                _memberWallet: _membersWallet, // The member wallet
                _parentWallet: _parentWallet, // The parent wallet
                _memberState: MemberState.Inactive // Set to inactive until the KYC is verified
            });

            (_reserve) = _calculateReferralRewards(
                _reserve,
                _couponAmount,
                _membersWallet,
                _parentWallet
            );

            _newMember.discount = discount;
        } else {
            // Flow 2: Join (with flow 1) -> Refund -> Join
            // If is refunded, the member exist already, but was previously refunded
            _newMember = _updateMember({
                _drr: _reserve.dynamicReserveRatio,
                _benefitMultiplier: _benefitMultiplier,
                _membershipDuration: _membershipDuration, // From the input
                _memberWallet: _membersWallet, // The member wallet
                _memberState: MemberState.Inactive, // Set to inactive until the KYC is verified
                _isKYCVerified: _newMember.isKYCVerified, // The current state, in this case false
                _isRefunded: false, // Reset to false as the user repays the contribution
                _allowCustomDuration: _reserve.allowCustomDuration,
                _member: _newMember
            });
        }
        // The member will pay the contribution, but will remain inactive until the KYC is verified
        // This means the proformas wont be updated, the amounts wont be added to the reserves,
        // the cash flow mappings wont change, the DRR and BMA wont be updated, the tokens wont be minted
        _transferContributionToModule({
            _memberWallet: _membersWallet,
            _couponAmount: _couponAmount
        });

        _setNewReserveAndMemberValuesHook(takasureReserve, _reserve, _newMember);
    }

    function _calculateReferralRewards(
        Reserve memory _reserve,
        uint256 _couponAmount,
        address _child,
        address _parent
    ) internal returns (Reserve memory) {
        // The prepaid member object is created
        uint256 realContribution = _getRealContributionAfterCoupon(_couponAmount);

        uint256 toReferralReserve;

        if (_reserve.referralDiscount) {
            toReferralReserve = (realContribution * REFERRAL_RESERVE) / 100;

            if (_parent != address(0)) {
                discount = ((realContribution - _couponAmount) * REFERRAL_DISCOUNT_RATIO) / 100;

                childToParent[_child] = _parent;

                (feeAmount, _reserve.referralReserve) = _parentRewards({
                    _initialChildToCheck: _child,
                    _contribution: realContribution,
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

    function _getRealContributionAfterCoupon(
        uint256 _couponAmount
    ) internal view returns (uint256 realContribution_) {
        if (_couponAmount > normalizedContributionBeforeFee) realContribution_ = _couponAmount;
        else realContribution_ = normalizedContributionBeforeFee;
    }

    function _parentRewards(
        address _initialChildToCheck,
        uint256 _contribution,
        uint256 _currentReferralReserve,
        uint256 _toReferralReserve,
        uint256 _currentFee
    ) internal override returns (uint256, uint256) {
        address currentChildToCheck = _initialChildToCheck;
        uint256 newReferralReserveBalance = _currentReferralReserve + _toReferralReserve;
        uint256 parentRewardsAccumulated;

        for (int256 i; i < MAX_TIER; ++i) {
            if (childToParent[currentChildToCheck] == address(0)) {
                break;
            }

            parentRewardsByChild[childToParent[currentChildToCheck]][_initialChildToCheck] =
                (_contribution * _referralRewardRatioByLayer(i + 1)) /
                (100 * DECIMAL_CORRECTION);

            parentRewardsByLayer[childToParent[currentChildToCheck]][uint256(i + 1)] +=
                (_contribution * _referralRewardRatioByLayer(i + 1)) /
                (100 * DECIMAL_CORRECTION);

            parentRewardsAccumulated +=
                (_contribution * _referralRewardRatioByLayer(i + 1)) /
                (100 * DECIMAL_CORRECTION);

            currentChildToCheck = childToParent[currentChildToCheck];
        }

        if (newReferralReserveBalance > parentRewardsAccumulated) {
            newReferralReserveBalance -= parentRewardsAccumulated;
        } else {
            uint256 reserveShortfall = parentRewardsAccumulated - newReferralReserveBalance;
            _currentFee -= reserveShortfall;
            newReferralReserveBalance = 0;
        }

        return (_currentFee, newReferralReserveBalance);
    }

    function _refund(address _memberWallet) internal {
        AddressAndStates._onlyModuleState(moduleState, ModuleState.Enabled);
        (Reserve memory _reserve, Member memory _member) = _getReserveAndMemberValuesHook(
            takasureReserve,
            _memberWallet
        );

        // The member should not be KYCed neither already refunded
        require(!_member.isKYCVerified, EntryModule__MemberAlreadyKYCed());
        require(!_member.isRefunded, EntryModule__NothingToRefund());

        uint256 currentTimestamp = block.timestamp;
        uint256 membershipStartTime = _member.membershipStartTime;
        // The member can refund after 14 days of the payment
        uint256 limitTimestamp = membershipStartTime + (14 days);
        require(currentTimestamp >= limitTimestamp, EntryModule__TooEarlytoRefund());

        // No need to check if contribution amounnt is 0, as the member only is created with the contribution 0
        // when first KYC and then join the pool. So the previous check is enough

        // As there is only one contribution, is easy to calculte with the Member struct values
        uint256 contributionAmount = _member.contribution;
        uint256 serviceFeeAmount = _member.totalServiceFee;
        uint256 amountToRefund = contributionAmount - serviceFeeAmount;

        // Update the member values
        _member.isRefunded = true;
        // Transfer the amount to refund
        IERC20(_reserve.contributionToken).safeTransfer(_memberWallet, amountToRefund);

        emit TakasureEvents.OnRefund(_member.memberId, _memberWallet, amountToRefund);

        _setMembersValuesHook(takasureReserve, _member);
    }

    function _calculateAmountAndFees(uint256 _contributionBeforeFee, uint256 _fee) internal {
        // Then we pay the contribution
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
            memberSurplus: 0, // Todo
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

    function _updateMember(
        uint256 _drr,
        uint256 _benefitMultiplier,
        uint256 _membershipDuration,
        address _memberWallet,
        MemberState _memberState,
        bool _isKYCVerified,
        bool _isRefunded,
        bool _allowCustomDuration,
        Member memory _member
    ) internal returns (Member memory) {
        uint256 userMembershipDuration;
        uint256 claimAddAmount = ((normalizedContributionBeforeFee - feeAmount) * (100 - _drr)) /
            100;

        if (_allowCustomDuration) {
            userMembershipDuration = _membershipDuration;
        } else {
            userMembershipDuration = ModuleConstants.DEFAULT_MEMBERSHIP_DURATION;
        }

        _member.benefitMultiplier = _benefitMultiplier;
        _member.membershipDuration = userMembershipDuration;
        _member.membershipStartTime = block.timestamp;
        _member.contribution = normalizedContributionBeforeFee;
        _member.claimAddAmount = claimAddAmount;
        _member.totalServiceFee = feeAmount;
        _member.memberState = _memberState;
        _member.isKYCVerified = _isKYCVerified;
        _member.isRefunded = _isRefunded;

        emit TakasureEvents.OnMemberUpdated(
            _member.memberId,
            _memberWallet,
            _benefitMultiplier,
            normalizedContributionBeforeFee,
            feeAmount,
            userMembershipDuration,
            block.timestamp
        );

        return _member;
    }

    function _memberPaymentFlow(
        uint256 _contributionBeforeFee,
        uint256 _contributionAfterFee,
        address _memberWallet,
        Reserve memory _reserve,
        ITakasureReserve _takasureReserve
    ) internal override returns (Reserve memory, uint256) {
        _getBenefitMultiplierFromOracle(_memberWallet);
        return
            super._memberPaymentFlow(
                _contributionBeforeFee,
                _contributionAfterFee,
                _memberWallet,
                _reserve,
                _takasureReserve
            );
    }

    function _transferContribution(
        IERC20 _contributionToken,
        address,
        address _takasureReserve,
        uint256 _contributionAfterFee
    ) internal override {
        // If the caller is from the prejoin module, the transfer will be done by the prejoin module
        // to the takasure reserve. Otherwise, the transfer will be done by this contract
        if (msg.sender != prejoinModule) {
            _contributionToken.safeTransfer(_takasureReserve, _contributionAfterFee - discount);
        }
    }

    function _getBenefitMultiplierFromOracle(
        address _member
    ) internal returns (uint256 benefitMultiplier_) {
        Member memory member = _getMembersValuesHook(takasureReserve, _member);

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
                member.benefitMultiplier = benefitMultiplier_;
            } else {
                // If failed we get the error and revert with it
                bytes memory errorResponse = bmConsumer.idToErrorResponse(requestId);
                revert EntryModule__BenefitMultiplierRequestFailed(errorResponse);
            }
        }
    }

    function _monthAndDayFromCall()
        internal
        view
        returns (uint16 currentMonth_, uint8 currentDay_)
    {
        CashFlowVars memory cashFlowVars = takasureReserve.getCashFlowValues();
        uint256 currentTimestamp = block.timestamp;
        uint256 lastDayDepositTimestamp = cashFlowVars.dayDepositTimestamp;
        uint256 lastMonthDepositTimestamp = cashFlowVars.monthDepositTimestamp;

        // Calculate how many days and months have passed since the last deposit and the current timestamp
        uint256 daysPassed = ReserveMathAlgorithms._calculateDaysPassed(
            currentTimestamp,
            lastDayDepositTimestamp
        );
        uint256 monthsPassed = ReserveMathAlgorithms._calculateMonthsPassed(
            currentTimestamp,
            lastMonthDepositTimestamp
        );

        if (monthsPassed == 0) {
            // If  no months have passed, current month is the reference
            currentMonth_ = cashFlowVars.monthReference;
            if (daysPassed == 0) {
                // If no days have passed, current day is the reference
                currentDay_ = cashFlowVars.dayReference;
            } else {
                // If you are in a new day, calculate the days passed
                currentDay_ = uint8(daysPassed) + cashFlowVars.dayReference;
            }
        } else {
            // If you are in a new month, calculate the months passed
            currentMonth_ = uint16(monthsPassed) + cashFlowVars.monthReference;
            // Calculate the timestamp when this new month started
            uint256 timestampThisMonthStarted = lastMonthDepositTimestamp +
                (monthsPassed * ModuleConstants.MONTH);
            // And calculate the days passed in this new month using the new month timestamp
            daysPassed = ReserveMathAlgorithms._calculateDaysPassed(
                currentTimestamp,
                timestampThisMonthStarted
            );
            // The current day is the days passed in this new month
            uint8 initialDay = 1;
            currentDay_ = uint8(daysPassed) + initialDay;
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
            if (msg.sender == ccipReceiverContract) {
                contributionToken.safeTransferFrom(
                    ccipReceiverContract,
                    address(this),
                    _amountToTransferFromMember
                );

                // Note: This is a temporary solution to test the CCIP integration in the testnet
                // This is because in testnet we are using a different USDC contract for easier testing
                // IERC20(0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d).safeTransferFrom(
                //     ccipReceiverContract,
                //     address(this),
                //     amountToTransfer
                // );
            } else {
                contributionToken.safeTransferFrom(
                    _memberWallet,
                    address(this),
                    _amountToTransferFromMember
                );
            }

            // Transfer the coupon amount to this contract
            if (_couponAmount > 0) {
                contributionToken.safeTransferFrom(couponPool, address(this), _couponAmount);
            }

            // Transfer the service fee to the fee claim address
            contributionToken.safeTransferFrom(
                _memberWallet,
                takasureReserve.feeClaimAddress(),
                feeAmount
            );
        }
    }

    function _onlyCouponRedeemerOrCcipReceiver() internal view {
        require(
            hasRole(ModuleConstants.COUPON_REDEEMER, msg.sender) || msg.sender == ccipReceiverContract,
            EntryModule__NotAuthorizedCaller()
        );
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(ModuleConstants.TAKADAO_OPERATOR) {}
}
