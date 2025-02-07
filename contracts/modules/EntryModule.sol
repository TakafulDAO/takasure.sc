//SPDX-License-Identifier: GPL-3.0

/**
 * @title EntryModule
 * @author Maikel Ordaz
 * @notice This contract manage all the process to become a member
 * @dev It will interact with the TakasureReserve contract to update the values
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBenefitMultiplierConsumer} from "contracts/interfaces/IBenefitMultiplierConsumer.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {ITSToken} from "contracts/interfaces/ITSToken.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {ModuleCheck} from "contracts/modules/moduleUtils/ModuleCheck.sol";
import {ReserveAndMemberValuesHook} from "contracts/hooks/ReserveAndMemberValuesHook.sol";

import {Reserve, Member, MemberState, CashFlowVars} from "contracts/types/TakasureTypes.sol";
import {ModuleConstants} from "contracts/helpers/libraries/ModuleConstants.sol";
import {ReserveMathLib} from "contracts/helpers/libraries/ReserveMathLib.sol";
import {CashFlowAlgorithms} from "contracts/helpers/libraries/CashFlowAlgorithms.sol";
import {TakasureEvents} from "contracts/helpers/libraries/TakasureEvents.sol";
import {GlobalErrors} from "contracts/helpers/libraries/GlobalErrors.sol";
import {ModuleErrors} from "contracts/helpers/libraries/ModuleErrors.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract EntryModule is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    ModuleCheck,
    ReserveAndMemberValuesHook
{
    using SafeERC20 for IERC20;

    ITakasureReserve private takasureReserve;
    IBenefitMultiplierConsumer private bmConsumer;

    uint256 private transient mintedTokens;
    uint256 private transient normalizedContributionBeforeFee;
    uint256 private transient feeAmount;
    uint256 private transient contributionAfterFee;

    error EntryModule__NoContribution();
    error EntryModule__ContributionOutOfRange();
    error EntryModule__AlreadyJoinedPendingForKYC();
    error EntryModule__BenefitMultiplierRequestFailed(bytes errorResponse);
    error EntryModule__MemberAlreadyKYCed();
    error EntryModule__NothingToRefund();
    error EntryModule__TooEarlytoRefund();

    modifier notZeroAddress(address _address) {
        require(_address != address(0), GlobalErrors.TakasureProtocol__ZeroAddress());
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _takasureReserveAddress) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuardTransient_init();

        takasureReserve = ITakasureReserve(_takasureReserveAddress);
        bmConsumer = IBenefitMultiplierConsumer(takasureReserve.bmConsumer());
        address takadaoOperator = takasureReserve.takadaoOperator();

        _grantRole(DEFAULT_ADMIN_ROLE, takadaoOperator);
        _grantRole(ModuleConstants.TAKADAO_OPERATOR, takadaoOperator);
        _grantRole(ModuleConstants.KYC_PROVIDER, takasureReserve.kycProvider());
    }

    /**
     * @notice Allow new members to join the pool. If the member is not KYCed, it will be created as inactive
     *         until the KYC is verified.If the member is already KYCed, the contribution will be paid and the
     *         member will be active.
     * @param mebersWallet address of the member
     * @param contributionBeforeFee in six decimals
     * @param membershipDuration default 5 years
     * @dev it reverts if the contribution is less than the minimum threshold defaultes to `minimumThreshold`
     * @dev it reverts if the member is already active
     * @dev the contribution amount will be round down so the last four decimals will be zero. This means
     *      that the minimum contribution amount is 0.01 USDC
     * @dev the contribution amount will be round down so the last four decimals will be zero
     */
    function joinPool(
        address mebersWallet,
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external nonReentrant {
        (Reserve memory reserve, Member memory newMember) = _getReserveAndMemberValuesHook(takasureReserve, mebersWallet);

        require(
            newMember.memberState == MemberState.Inactive,
            ModuleErrors.Module__WrongMemberState()
        );
        require(
            contributionBeforeFee >= reserve.minimumThreshold &&
                contributionBeforeFee <= reserve.maximumThreshold,
            EntryModule__ContributionOutOfRange()
        );

        _calculateAmountAndFees(contributionBeforeFee, reserve.serviceFee);

        uint256 benefitMultiplier = _getBenefitMultiplierFromOracle(mebersWallet);

        if (!newMember.isRefunded) {
            // Flow 1: Join -> KYC
            require(newMember.wallet == address(0), EntryModule__AlreadyJoinedPendingForKYC());
            // If is not refunded, it is a completele new member, we create it
            newMember = _createNewMember({
                _newMemberId: ++reserve.memberIdCounter,
                _allowCustomDuration: reserve.allowCustomDuration,
                _drr: reserve.dynamicReserveRatio,
                _benefitMultiplier: benefitMultiplier, // Fetch from oracle
                _membershipDuration: membershipDuration, // From the input
                _isKYCVerified: newMember.isKYCVerified, // The current state, in this case false
                _memberWallet: mebersWallet, // The member wallet
                _memberState: MemberState.Inactive // Set to inactive until the KYC is verified
            });
        } else {
            // Flow 2: Join (with flow 1) -> Refund -> Join
            // If is refunded, the member exist already, but was previously refunded
            newMember = _updateMember({
                _drr: reserve.dynamicReserveRatio,
                _benefitMultiplier: benefitMultiplier,
                _membershipDuration: membershipDuration, // From the input
                _memberWallet: mebersWallet, // The member wallet
                _memberState: MemberState.Inactive, // Set to inactive until the KYC is verified
                _isKYCVerified: newMember.isKYCVerified, // The current state, in this case false
                _isRefunded: false, // Reset to false as the user repays the contribution
                _allowCustomDuration: reserve.allowCustomDuration,
                _member: newMember
            });
        }
        // The member will pay the contribution, but will remain inactive until the KYC is verified
        // This means the proformas wont be updated, the amounts wont be added to the reserves,
        // the cash flow mappings wont change, the DRR and BMA wont be updated, the tokens wont be minted
        _transferContributionToModule({_memberWallet: mebersWallet});

        _setNewReserveAndMemberValuesHook(
            takasureReserve,
            reserve,
            newMember
        );
    }

    /**
     * @notice Set the KYC status of a member. If the member does not exist, it will be created as inactive
     *         until the contribution is paid with joinPool. If the member has already joined the pool, then
     *         the contribution will be paid and the member will be active.
     * @param memberWallet address of the member
     * @dev It reverts if the member is the zero address
     * @dev It reverts if the member is already KYCed
     */
    function setKYCStatus(
        address memberWallet
    ) external notZeroAddress(memberWallet) onlyRole(ModuleConstants.KYC_PROVIDER) {
        (Reserve memory reserve, Member memory newMember) = _getReserveAndMemberValuesHook(takasureReserve, memberWallet);

        require(!newMember.isKYCVerified, EntryModule__MemberAlreadyKYCed());
        require(
            newMember.memberState == MemberState.Inactive,
            ModuleErrors.Module__WrongMemberState()
        );
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
        reserve = _memberPaymentFlow({
            _contributionBeforeFee: newMember.contribution,
            _contributionAfterFee: contributionAfterFee,
            _memberWallet: memberWallet,
            _reserve: reserve
        });

        newMember.creditTokensBalance += mintedTokens;

        emit TakasureEvents.OnMemberKycVerified(newMember.memberId, memberWallet);
        emit TakasureEvents.OnMemberJoined(newMember.memberId, memberWallet);

        _setNewReserveAndMemberValuesHook(
            takasureReserve,
            reserve,
            newMember
        );
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
    function refund(address memberWallet) external notZeroAddress(memberWallet) {
        _refund(memberWallet);
    }

    function updateBmAddress() external onlyRole(ModuleConstants.TAKADAO_OPERATOR) {
        bmConsumer = IBenefitMultiplierConsumer(takasureReserve.bmConsumer());
    }

    function _refund(address _memberWallet) internal {
        (Reserve memory _reserve, Member memory _member) = _getReserveAndMemberValuesHook(takasureReserve, _memberWallet);

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
            claimAddAmount: claimAddAmount,
            totalContributions: normalizedContributionBeforeFee,
            totalServiceFee: feeAmount,
            creditTokensBalance: 0,
            wallet: _memberWallet,
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
            block.timestamp
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

    /**
     * @notice This function will update all the variables needed when someone fully becomes a member
     * @dev It transfer the contribution from the module to the reserves
     */
    function _memberPaymentFlow(
        uint256 _contributionBeforeFee,
        uint256 _contributionAfterFee,
        address _memberWallet,
        Reserve memory _reserve
    ) internal returns (Reserve memory) {
        _getBenefitMultiplierFromOracle(_memberWallet);

        _reserve = CashFlowAlgorithms._updateNewReserveValues(
            takasureReserve,
            _contributionAfterFee,
            _contributionBeforeFee,
            _reserve
        );

        // Transfer the contribution to the reserves
        IERC20(_reserve.contributionToken).safeTransfer(
            address(takasureReserve),
            _contributionAfterFee
        );

        // Mint the DAO Tokens
        mintedTokens = CashFlowAlgorithms._mintDaoTokens(takasureReserve, _contributionBeforeFee);

        return _reserve;
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
        uint256 daysPassed = ReserveMathLib._calculateDaysPassed(
            currentTimestamp,
            lastDayDepositTimestamp
        );
        uint256 monthsPassed = ReserveMathLib._calculateMonthsPassed(
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
            daysPassed = ReserveMathLib._calculateDaysPassed(
                currentTimestamp,
                timestampThisMonthStarted
            );
            // The current day is the days passed in this new month
            uint8 initialDay = 1;
            currentDay_ = uint8(daysPassed) + initialDay;
        }
    }

    function _transferContributionToModule(address _memberWallet) internal {
        IERC20 contributionToken = IERC20(takasureReserve.getReserveValues().contributionToken);

        // Store temporarily the contribution in this contract, this way will be available for refunds
        contributionToken.safeTransferFrom(_memberWallet, address(this), contributionAfterFee);

        // Transfer the service fee to the fee claim address
        contributionToken.safeTransferFrom(
            _memberWallet,
            takasureReserve.feeClaimAddress(),
            feeAmount
        );
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(ModuleConstants.TAKADAO_OPERATOR) {}
}
