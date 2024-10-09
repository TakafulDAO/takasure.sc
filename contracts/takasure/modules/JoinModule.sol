//SPDX-License-Identifier: GPL-3.0

/**
 * @title JoinModule
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

import {NewReserve, Member, MemberState, CashFlowVars} from "contracts/types/TakasureTypes.sol";
import {ReserveMathLib} from "contracts/libraries/ReserveMathLib.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {TakasureErrors} from "contracts/libraries/TakasureErrors.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

pragma solidity 0.8.25;

contract JoinModule is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransientUpgradeable
{
    ITakasureReserve private takasureReserve;
    IBenefitMultiplierConsumer private bmConsumer;

    bytes32 private constant TAKADAO_OPERATOR = keccak256("TAKADAO_OPERATOR");
    bytes32 private constant KYC_PROVIDER = keccak256("KYC_PROVIDER");

    uint256 private constant DECIMALS_PRECISION = 1e12;
    uint256 private constant DECIMAL_REQUIREMENT_PRECISION_USDC = 1e4; // 4 decimals to receive at minimum 0.01 USDC
    uint256 private constant DEFAULT_MEMBERSHIP_DURATION = 5 * (365 days); // 5 year
    uint256 private constant MONTH = 30 days; // Todo: manage a better way for 365 days and leap years maybe?
    uint256 private constant DAY = 1 days;

    modifier notZeroAddress(address _address) {
        if (_address == address(0)) {
            revert TakasureErrors.TakasurePool__ZeroAddress();
        }
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
        _grantRole(TAKADAO_OPERATOR, takadaoOperator);
        _grantRole(KYC_PROVIDER, takasureReserve.kycProvider());
    }

    /**
     * @notice Allow new members to join the pool. If the member is not KYCed, it will be created as inactive
     *         until the KYC is verified.If the member is already KYCed, the contribution will be paid and the
     *         member will be active.
     * @param contributionBeforeFee in six decimals
     * @param membershipDuration default 5 years
     * @dev it reverts if the contribution is less than the minimum threshold defaultes to `minimumThreshold`
     * @dev it reverts if the member is already active
     * @dev the contribution amount will be round down so the last four decimals will be zero. This means
     *      that the minimum contribution amount is 0.01 USDC
     * @dev the contribution amount will be round down so the last four decimals will be zero
     */
    function joinPool(
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external nonReentrant {
        (NewReserve memory newReserve, Member memory newMember) = _getReserveAndMemberValuesHook(
            msg.sender
        );

        if (newMember.memberState != MemberState.Inactive) {
            revert TakasureErrors.TakasurePool__WrongMemberState();
        }
        if (
            contributionBeforeFee < newReserve.minimumThreshold ||
            contributionBeforeFee > newReserve.maximumThreshold
        ) {
            revert TakasureErrors.TakasurePool__ContributionOutOfRange();
        }

        uint256 mintAmount;

        (
            uint256 normalizedContributionBeforeFee,
            uint256 feeAmount,
            uint256 contributionAfterFee
        ) = _calculateAmountAndFees(contributionBeforeFee, newReserve.serviceFee);

        if (newMember.isKYCVerified) {
            // Flow 1 KYC -> Join
            // It means the user is already in the system, we just need to update the values
            newMember = _updateMember({
                _drr: newReserve.dynamicReserveRatio,
                _benefitMultiplier: _getBenefitMultiplierFromOracle(msg.sender), // Will be fetched from off-chain oracle
                _contributionBeforeFee: normalizedContributionBeforeFee, // From the input
                _membershipDuration: membershipDuration, // From the input
                _feeAmount: feeAmount, // Calculated
                _memberWallet: msg.sender, // The member wallet
                _memberState: MemberState.Active, // Active state as it is already KYCed and paid the contribution
                _isKYCVerified: newMember.isKYCVerified, // The current state, does not change here
                _isRefunded: false, // Reset to false as the user repays the contribution
                _allowCustomDuration: newReserve.allowCustomDuration,
                _member: newMember
            });

            // And we pay the contribution
            (newReserve, mintAmount) = _memberPaymentFlow({
                _contributionBeforeFee: normalizedContributionBeforeFee,
                _contributionAfterFee: contributionAfterFee,
                _memberWallet: msg.sender,
                _payContribution: true,
                _sendToReserve: true,
                _reserve: newReserve
            });

            newMember.creditTokensBalance += mintAmount;
            emit TakasureEvents.OnMemberJoined(newMember.memberId, msg.sender);
        } else {
            if (!newMember.isRefunded) {
                // Flow 2 Join -> KYC
                if (newMember.wallet != address(0)) {
                    revert TakasureErrors.TakasurePool__AlreadyJoinedPendingForKYC();
                }
                // If is not KYC verified, and not refunded, it is a completele new member, we create it
                newMember = _createNewMember({
                    _newMemberId: ++newReserve.memberIdCounter,
                    _allowCustomDuration: newReserve.allowCustomDuration,
                    _drr: newReserve.dynamicReserveRatio,
                    _benefitMultiplier: _getBenefitMultiplierFromOracle(msg.sender), // Fetch from oracle
                    _contributionBeforeFee: normalizedContributionBeforeFee, // From the input
                    _membershipDuration: membershipDuration, // From the input
                    _feeAmount: feeAmount, // Calculated
                    _isKYCVerified: newMember.isKYCVerified, // The current state, in this case false
                    _memberWallet: msg.sender, // The member wallet
                    _memberState: MemberState.Inactive // Set to inactive until the KYC is verified
                });
            } else {
                // Flow 3 Refund -> Join
                // If is not KYC verified, but refunded, the member exist already, but was previously refunded
                newMember = _updateMember({
                    _drr: newReserve.dynamicReserveRatio,
                    _benefitMultiplier: _getBenefitMultiplierFromOracle(msg.sender),
                    _contributionBeforeFee: normalizedContributionBeforeFee, // From the input
                    _membershipDuration: membershipDuration, // From the input
                    _feeAmount: feeAmount, // Calculated
                    _memberWallet: msg.sender, // The member wallet
                    _memberState: MemberState.Inactive, // Set to inactive until the KYC is verified
                    _isKYCVerified: newMember.isKYCVerified, // The current state, in this case false
                    _isRefunded: false, // Reset to false as the user repays the contribution
                    _allowCustomDuration: newReserve.allowCustomDuration,
                    _member: newMember
                });
            }

            // The member will pay the contribution, but will remain inactive until the KYC is verified
            // This means the proformas wont be updated, the amounts wont be added to the reserves,
            // the cash flow mappings wont change, the DRR and BMA wont be updated, the tokens wont be minted
            mintAmount = _transferAmounts({
                _contributionAfterFee: contributionAfterFee,
                _contributionBeforeFee: contributionBeforeFee,
                _memberWallet: msg.sender,
                _mintTokens: false,
                _sendToReserve: false
            });

            newMember.creditTokensBalance += mintAmount;
        }

        _setNewReserveAndMemberValuesHook(newReserve, newMember);
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
    ) external notZeroAddress(memberWallet) onlyRole(KYC_PROVIDER) {
        (NewReserve memory newReserve, Member memory newMember) = _getReserveAndMemberValuesHook(
            memberWallet
        );

        if (newMember.isKYCVerified) {
            revert TakasureErrors.TakasurePool__MemberAlreadyKYCed();
        }

        uint256 mintAmount;

        if (newMember.wallet == address(0)) {
            // Flow 1 KYC -> Join
            // This means the user does not exist yet
            newMember = _createNewMember({
                _newMemberId: ++newReserve.memberIdCounter,
                _allowCustomDuration: newReserve.allowCustomDuration,
                _drr: newReserve.dynamicReserveRatio,
                _benefitMultiplier: _getBenefitMultiplierFromOracle(memberWallet),
                _contributionBeforeFee: 0, // We dont know it yet
                _membershipDuration: 0, // We dont know it yet
                _feeAmount: 0, // We dont know it yet
                _isKYCVerified: true, // Set to true with this call
                _memberWallet: memberWallet, // The member wallet
                _memberState: MemberState.Inactive // Set to inactive until the contribution is paid
            });
        } else {
            if (!newMember.isRefunded) {
                // Flow 2 Join -> KYC
                // This means the user exists and payed contribution but is not KYCed yet, we update the values
                (
                    uint256 normalizedContributionBeforeFee,
                    uint256 feeAmount,
                    uint256 contributionAfterFee
                ) = _calculateAmountAndFees(newMember.contribution, newReserve.serviceFee);

                newMember = _updateMember({
                    _drr: newReserve.dynamicReserveRatio, // We take the current value
                    _benefitMultiplier: _getBenefitMultiplierFromOracle(memberWallet), // We take the current value
                    _contributionBeforeFee: normalizedContributionBeforeFee, // We take the current value
                    _membershipDuration: newMember.membershipDuration, // We take the current value
                    _feeAmount: feeAmount, // Calculated
                    _memberWallet: memberWallet, // The member wallet
                    _memberState: MemberState.Active, // Active state as the user is already paid the contribution and KYCed
                    _isKYCVerified: true, // Set to true with this call
                    _isRefunded: false, // Remains false as the user is not refunded
                    _allowCustomDuration: newReserve.allowCustomDuration,
                    _member: newMember
                });

                // Then the everyting needed will be updated, proformas, reserves, cash flow,
                // DRR, BMA, tokens minted, no need to transfer the amounts as they are already paid
                (newReserve, mintAmount) = _memberPaymentFlow({
                    _contributionBeforeFee: normalizedContributionBeforeFee,
                    _contributionAfterFee: contributionAfterFee,
                    _memberWallet: memberWallet,
                    _payContribution: false,
                    _sendToReserve: false,
                    _reserve: newReserve
                });

                newMember.creditTokensBalance += mintAmount;
                emit TakasureEvents.OnMemberJoined(newMember.memberId, memberWallet);
            } else {
                // Flow 4 Refund -> KYC
                // This means the user exists, but was refunded, we reset the values
                newMember = _updateMember({
                    _drr: newReserve.dynamicReserveRatio, // We take the current value
                    _benefitMultiplier: _getBenefitMultiplierFromOracle(memberWallet), // As the B, does not change, we can avoid re-fetching
                    _contributionBeforeFee: 0, // Reset until the user pays the contribution
                    _membershipDuration: 0, // Reset until the user pays the contribution
                    _feeAmount: 0, // Reset until the user pays the contribution
                    _memberWallet: memberWallet, // The member wallet
                    _memberState: MemberState.Inactive, // Set to inactive until the contribution is paid
                    _isKYCVerified: true, // Set to true with this call
                    _isRefunded: true, // Remains true until the user pays the contribution
                    _allowCustomDuration: newReserve.allowCustomDuration,
                    _member: newMember
                });
            }
        }
        emit TakasureEvents.OnMemberKycVerified(newMember.memberId, memberWallet);

        _setNewReserveAndMemberValuesHook(newReserve, newMember);
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

    function updateBmAddress() external onlyRole(TAKADAO_OPERATOR) {
        bmConsumer = IBenefitMultiplierConsumer(takasureReserve.bmConsumer());
    }

    function _getReserveAndMemberValuesHook(
        address _memberWallet
    ) internal view returns (NewReserve memory reserve_, Member memory member_) {
        reserve_ = takasureReserve.getReserveValues();
        member_ = takasureReserve.getMemberFromAddress(_memberWallet);
    }

    function _setNewReserveAndMemberValuesHook(
        NewReserve memory _newReserve,
        Member memory _newMember
    ) internal {
        takasureReserve.setReserveValuesFromModule(_newReserve);
        takasureReserve.setMemberValuesFromModule(_newMember);
    }

    function _refund(address _memberWallet) internal {
        (NewReserve memory _newReserve, Member memory _member) = _getReserveAndMemberValuesHook(
            _memberWallet
        );

        // The member should not be KYCed neither already refunded
        if (_member.isKYCVerified == true) {
            revert TakasureErrors.TakasurePool__MemberAlreadyKYCed();
        }
        if (_member.isRefunded == true) {
            revert TakasureErrors.TakasurePool__NothingToRefund();
        }
        uint256 currentTimestamp = block.timestamp;
        uint256 membershipStartTime = _member.membershipStartTime;
        // The member can refund after 14 days of the payment
        uint256 limitTimestamp = membershipStartTime + (14 days);
        if (currentTimestamp < limitTimestamp) {
            revert TakasureErrors.TakasurePool__TooEarlytoRefund();
        }
        // No need to check if contribution amounnt is 0, as the member only is created with the contribution 0
        // when first KYC and then join the pool. So the previous check is enough

        // As there is only one contribution, is easy to calculte with the Member struct values
        uint256 contributionAmount = _member.contribution;
        uint256 serviceFeeAmount = _member.totalServiceFee;
        uint256 amountToRefund = contributionAmount - serviceFeeAmount;

        // Update the member values
        _member.isRefunded = true;
        // Transfer the amount to refund
        bool success = IERC20(_newReserve.contributionToken).transfer(
            _memberWallet,
            amountToRefund
        );

        if (!success) {
            revert TakasureErrors.TakasurePool__RefundFailed();
        }

        emit TakasureEvents.OnRefund(_member.memberId, _memberWallet, amountToRefund);

        takasureReserve.setMemberValuesFromModule(_member);
    }

    function _calculateAmountAndFees(
        uint256 _contributionBeforeFee,
        uint256 _fee
    )
        internal
        pure
        returns (
            uint256 normalizedContributionBeforeFee_,
            uint256 feeAmount_,
            uint256 contributionAfterFee_
        )
    {
        // Then we pay the contribution
        // The minimum we can receive is 0,01 USDC, here we round it. This to prevent rounding errors
        // i.e. contributionAmount = (25.123456 / 1e4) * 1e4 = 25.12USDC
        normalizedContributionBeforeFee_ =
            (_contributionBeforeFee / DECIMAL_REQUIREMENT_PRECISION_USDC) *
            DECIMAL_REQUIREMENT_PRECISION_USDC;
        feeAmount_ = (normalizedContributionBeforeFee_ * _fee) / 100;
        contributionAfterFee_ = normalizedContributionBeforeFee_ - feeAmount_;
    }

    function _createNewMember(
        uint256 _newMemberId,
        bool _allowCustomDuration,
        uint256 _drr,
        uint256 _benefitMultiplier,
        uint256 _contributionBeforeFee,
        uint256 _membershipDuration,
        uint256 _feeAmount,
        bool _isKYCVerified,
        address _memberWallet,
        MemberState _memberState
    ) internal returns (Member memory) {
        uint256 userMembershipDuration;

        if (_allowCustomDuration) {
            userMembershipDuration = _membershipDuration;
        } else {
            userMembershipDuration = DEFAULT_MEMBERSHIP_DURATION;
        }

        uint256 claimAddAmount = ((_contributionBeforeFee - _feeAmount) * (100 - _drr)) / 100;

        Member memory newMember = Member({
            memberId: _newMemberId,
            benefitMultiplier: _benefitMultiplier,
            membershipDuration: userMembershipDuration,
            membershipStartTime: block.timestamp,
            lastPaidYearStartDate: block.timestamp,
            contribution: _contributionBeforeFee,
            claimAddAmount: claimAddAmount,
            totalContributions: _contributionBeforeFee,
            totalServiceFee: _feeAmount,
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
            _contributionBeforeFee,
            _feeAmount,
            userMembershipDuration,
            block.timestamp
        );

        return newMember;
    }

    function _updateMember(
        uint256 _drr,
        uint256 _benefitMultiplier,
        uint256 _contributionBeforeFee,
        uint256 _membershipDuration,
        uint256 _feeAmount,
        address _memberWallet,
        MemberState _memberState,
        bool _isKYCVerified,
        bool _isRefunded,
        bool _allowCustomDuration,
        Member memory _member
    ) internal returns (Member memory) {
        uint256 userMembershipDuration;
        uint256 claimAddAmount = ((_contributionBeforeFee - _feeAmount) * (100 - _drr)) / 100;

        if (_allowCustomDuration) {
            userMembershipDuration = _membershipDuration;
        } else {
            userMembershipDuration = DEFAULT_MEMBERSHIP_DURATION;
        }

        _member.benefitMultiplier = _benefitMultiplier;
        _member.membershipDuration = userMembershipDuration;
        _member.membershipStartTime = block.timestamp;
        _member.contribution = _contributionBeforeFee;
        _member.claimAddAmount = claimAddAmount;
        _member.totalServiceFee = _feeAmount;
        _member.memberState = _memberState;
        _member.isKYCVerified = _isKYCVerified;
        _member.isRefunded = _isRefunded;

        emit TakasureEvents.OnMemberUpdated(
            _member.memberId,
            _memberWallet,
            _benefitMultiplier,
            _contributionBeforeFee,
            _feeAmount,
            userMembershipDuration,
            block.timestamp
        );

        return _member;
    }

    /**
     * @notice This function will update all the variables needed when a member pays the contribution
     * @param _payContribution true -> the contribution will be paid and the credit tokens will be minted
     *                                      false -> no need to pay the contribution as it is already payed
     */
    function _memberPaymentFlow(
        uint256 _contributionBeforeFee,
        uint256 _contributionAfterFee,
        address _memberWallet,
        bool _payContribution,
        bool _sendToReserve,
        NewReserve memory _reserve
    ) internal returns (NewReserve memory, uint256 mintAmount_) {
        _getBenefitMultiplierFromOracle(_memberWallet);

        _reserve = _updateNewReserveValues(_contributionAfterFee, _contributionBeforeFee, _reserve);

        if (_payContribution) {
            mintAmount_ = _transferAmounts({
                _contributionAfterFee: _contributionAfterFee,
                _contributionBeforeFee: _contributionBeforeFee,
                _memberWallet: _memberWallet,
                _mintTokens: true,
                _sendToReserve: _sendToReserve
            });
        }

        return (_reserve, mintAmount_);
    }

    function _updateNewReserveValues(
        uint256 _contributionAfterFee,
        uint256 _contributionBeforeFee,
        NewReserve memory _reserve
    ) internal returns (NewReserve memory) {
        (
            uint256 updatedProFormaFundReserve,
            uint256 updatedProFormaClaimReserve
        ) = _updateProFormas(_contributionAfterFee, _contributionBeforeFee, _reserve);
        _reserve.proFormaFundReserve = updatedProFormaFundReserve;
        _reserve.proFormaClaimReserve = updatedProFormaClaimReserve;

        (
            uint256 toFundReserve,
            uint256 toClaimReserve,
            uint256 marketExpenditure
        ) = _updateReserveBalaces(_contributionAfterFee, _reserve);

        _reserve.totalFundReserve += toFundReserve;
        _reserve.totalClaimReserve += toClaimReserve;
        _reserve.totalContributions += _contributionBeforeFee;
        _reserve.totalFundCost += marketExpenditure;
        _reserve.totalFundRevenues += _contributionAfterFee;

        _updateCashMappings(_contributionAfterFee);
        uint256 cashLast12Months = _cashLast12Months();

        uint256 updatedDynamicReserveRatio = _updateDRR(cashLast12Months, _reserve);
        _reserve.dynamicReserveRatio = updatedDynamicReserveRatio;

        uint256 updatedBMA = _updateBMA(cashLast12Months, _reserve);
        _reserve.benefitMultiplierAdjuster = updatedBMA;

        uint256 lossRatio = _updateLossRatio(_reserve.totalFundCost, _reserve.totalFundRevenues);
        _reserve.lossRatio = lossRatio;

        return _reserve;
    }

    function _getBenefitMultiplierFromOracle(
        address _member
    ) internal returns (uint256 benefitMultiplier_) {
        Member memory member = takasureReserve.getMemberFromAddress(_member);
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
                revert TakasureErrors.TakasurePool__BenefitMultiplierRequestFailed(errorResponse);
            }
        }
    }

    function _updateProFormas(
        uint256 _contributionAfterFee,
        uint256 _contributionBeforeFee,
        NewReserve memory _reserve
    ) internal returns (uint256 updatedProFormaFundReserve_, uint256 updatedProFormaClaimReserve_) {
        updatedProFormaFundReserve_ = ReserveMathLib._updateProFormaFundReserve(
            _reserve.proFormaFundReserve,
            _contributionAfterFee,
            _reserve.initialReserveRatio
        );

        updatedProFormaClaimReserve_ = ReserveMathLib._updateProFormaClaimReserve(
            _reserve.proFormaClaimReserve,
            _contributionBeforeFee,
            _reserve.serviceFee,
            _reserve.initialReserveRatio
        );

        emit TakasureEvents.OnNewProFormaValues(
            updatedProFormaFundReserve_,
            updatedProFormaClaimReserve_
        );
    }

    function _updateReserveBalaces(
        uint256 _contributionAfterFee,
        NewReserve memory _reserve
    )
        internal
        returns (uint256 toFundReserve_, uint256 toClaimReserve_, uint256 marketExpenditure_)
    {
        uint256 toFundReserveBeforeExpenditures = (_contributionAfterFee *
            _reserve.dynamicReserveRatio) / 100;

        marketExpenditure_ =
            (toFundReserveBeforeExpenditures * _reserve.fundMarketExpendsAddShare) /
            100;

        toFundReserve_ = toFundReserveBeforeExpenditures - marketExpenditure_;
        toClaimReserve_ = _contributionAfterFee - toFundReserveBeforeExpenditures;

        emit TakasureEvents.OnNewReserveValues(
            _reserve.totalContributions,
            _reserve.totalClaimReserve,
            _reserve.totalFundReserve,
            _reserve.totalFundCost
        );
    }

    function _updateLossRatio(
        uint256 _totalFundCost,
        uint256 _totalFundRevenues
    ) internal returns (uint256 lossRatio_) {
        lossRatio_ = ReserveMathLib._calculateLossRatio(_totalFundCost, _totalFundRevenues);
        emit TakasureEvents.OnNewLossRatio(lossRatio_);
    }

    function _updateCashMappings(uint256 _cashIn) internal {
        CashFlowVars memory cashFlowVars = takasureReserve.getCashFlowValues();

        uint256 currentTimestamp = block.timestamp;
        uint256 prevCashIn;

        if (cashFlowVars.dayDepositTimestamp == 0 && cashFlowVars.monthDepositTimestamp == 0) {
            // If the depositTimestamp is 0 it means it is the first deposit
            // Set the initial values for future calculations and reference
            cashFlowVars.dayDepositTimestamp = currentTimestamp;
            cashFlowVars.monthDepositTimestamp = currentTimestamp;
            takasureReserve.setMonthToCashFlowValuesFromModule(
                cashFlowVars.monthReference,
                _cashIn
            );
            takasureReserve.setDayToCashFlowValuesFromModule(
                cashFlowVars.monthReference,
                cashFlowVars.dayReference,
                _cashIn
            );
        } else {
            // Check how many days and months have passed since the last deposit
            uint256 daysPassed = ReserveMathLib._calculateDaysPassed(
                currentTimestamp,
                cashFlowVars.dayDepositTimestamp
            );
            uint256 monthsPassed = ReserveMathLib._calculateMonthsPassed(
                currentTimestamp,
                cashFlowVars.monthDepositTimestamp
            );

            if (monthsPassed == 0) {
                // If no months have passed, update the mapping for the current month
                prevCashIn = takasureReserve.monthToCashFlow(cashFlowVars.monthReference);
                takasureReserve.setMonthToCashFlowValuesFromModule(
                    cashFlowVars.monthReference,
                    prevCashIn + _cashIn
                );
                if (daysPassed == 0) {
                    // If no days have passed, update the mapping for the current day
                    prevCashIn = takasureReserve.dayToCashFlow(
                        cashFlowVars.monthReference,
                        cashFlowVars.dayReference
                    );
                    takasureReserve.setDayToCashFlowValuesFromModule(
                        cashFlowVars.monthReference,
                        cashFlowVars.dayReference,
                        prevCashIn + _cashIn
                    );
                } else {
                    // If it is a new day, update the day deposit timestamp and the new day reference
                    cashFlowVars.dayDepositTimestamp += daysPassed * DAY;
                    cashFlowVars.dayReference += uint8(daysPassed);

                    // Update the mapping for the new day
                    takasureReserve.setDayToCashFlowValuesFromModule(
                        cashFlowVars.monthReference,
                        cashFlowVars.dayReference,
                        _cashIn
                    );
                }
            } else {
                // If it is a new month, update the month deposit timestamp and the day deposit timestamp
                // both should be the same as it is a new month
                cashFlowVars.monthDepositTimestamp += monthsPassed * MONTH;
                cashFlowVars.dayDepositTimestamp = cashFlowVars.monthDepositTimestamp;
                // Update the month reference to the corresponding month
                cashFlowVars.monthReference += uint16(monthsPassed);
                // Calculate the day reference for the new month, we need to recalculate the days passed
                // with the new day deposit timestamp
                daysPassed = ReserveMathLib._calculateDaysPassed(
                    currentTimestamp,
                    cashFlowVars.dayDepositTimestamp
                );
                // The new day reference is the days passed + initial day. Initial day refers
                // to the first day of the month
                uint8 initialDay = 1;
                cashFlowVars.dayReference = uint8(daysPassed) + initialDay;

                // Update the mappings for the new month and day
                takasureReserve.setMonthToCashFlowValuesFromModule(
                    cashFlowVars.monthReference,
                    _cashIn
                );
                takasureReserve.setDayToCashFlowValuesFromModule(
                    cashFlowVars.monthReference,
                    cashFlowVars.dayReference,
                    _cashIn
                );
            }
        }

        takasureReserve.setCashFlowValuesFromModule(cashFlowVars);
    }

    function _cashLast12Months() internal view returns (uint256 cashLast12Months_) {
        CashFlowVars memory cashFlowVars = takasureReserve.getCashFlowValues();
        uint16 _currentMonth = cashFlowVars.monthReference;
        uint8 _currentDay = cashFlowVars.dayReference;
        uint256 cash = 0;

        // Then make the iterations, according the month and day this function is called
        if (_currentMonth < 13) {
            // Less than a complete year, iterate through every month passed
            // Return everything stored in the mappings until now
            for (uint8 i = 1; i <= _currentMonth; ) {
                cash += takasureReserve.monthToCashFlow(i);

                unchecked {
                    ++i;
                }
            }
        } else {
            // More than a complete year has passed, iterate the last 11 completed months
            // This happens since month 13
            uint16 monthBackCounter;
            uint16 monthsInYear = 12;

            for (uint8 i; i < monthsInYear; ) {
                monthBackCounter = _currentMonth - i;
                cash += takasureReserve.monthToCashFlow(monthBackCounter);

                unchecked {
                    ++i;
                }
            }

            // Iterate an extra month to complete the days that are left from the current month
            uint16 extraMonthToCheck = _currentMonth - monthsInYear;
            uint8 dayBackCounter = 30;
            uint8 extraDaysToCheck = dayBackCounter - _currentDay;

            for (uint8 i; i < extraDaysToCheck; ) {
                cash += takasureReserve.dayToCashFlow(extraMonthToCheck, dayBackCounter);

                unchecked {
                    ++i;
                    --dayBackCounter;
                }
            }
        }

        cashLast12Months_ = cash;
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
            uint256 timestampThisMonthStarted = lastMonthDepositTimestamp + (monthsPassed * MONTH);
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

    function _updateDRR(
        uint256 _cash,
        NewReserve memory _reserve
    ) internal returns (uint256 updatedDynamicReserveRatio_) {
        updatedDynamicReserveRatio_ = ReserveMathLib._calculateDynamicReserveRatio(
            _reserve.initialReserveRatio,
            _reserve.proFormaFundReserve,
            _reserve.totalFundReserve,
            _cash
        );

        emit TakasureEvents.OnNewDynamicReserveRatio(updatedDynamicReserveRatio_);
    }

    function _updateBMA(
        uint256 _cash,
        NewReserve memory _reserve
    ) internal returns (uint256 updatedBMA_) {
        uint256 bmaInflowAssumption = ReserveMathLib._calculateBmaInflowAssumption(
            _cash,
            _reserve.serviceFee,
            _reserve.initialReserveRatio
        );

        updatedBMA_ = ReserveMathLib._calculateBmaCashFlowMethod(
            _reserve.totalClaimReserve,
            _reserve.totalFundReserve,
            _reserve.bmaFundReserveShare,
            _reserve.proFormaClaimReserve,
            bmaInflowAssumption
        );

        emit TakasureEvents.OnNewBenefitMultiplierAdjuster(updatedBMA_);
    }

    function _transferAmounts(
        uint256 _contributionAfterFee,
        uint256 _contributionBeforeFee,
        address _memberWallet,
        bool _mintTokens,
        bool _sendToReserve
    ) internal returns (uint256 mintAmount_) {
        IERC20 contributionToken = IERC20(takasureReserve.getReserveValues().contributionToken);
        bool success;
        uint256 feeAmount = _contributionBeforeFee - _contributionAfterFee;

        if (_sendToReserve) {
            // Transfer the contribution to the reserve
            success = contributionToken.transferFrom(
                _memberWallet,
                address(takasureReserve),
                _contributionAfterFee
            );
        } else {
            // Store temporarily the contribution in this contract, this way will be available for refunds
            success = contributionToken.transferFrom(
                _memberWallet,
                address(this),
                _contributionAfterFee
            );
        }

        if (!success) {
            revert TakasureErrors.TakasurePool__ContributionTransferFailed();
        }

        // Transfer the service fee to the fee claim address
        success = contributionToken.transferFrom(
            _memberWallet,
            takasureReserve.feeClaimAddress(),
            feeAmount
        );

        if (!success) {
            revert TakasureErrors.TakasurePool__FeeTransferFailed();
        }

        if (_mintTokens) {
            uint256 contributionBeforeFee = _contributionAfterFee + feeAmount;
            mintAmount_ = _mintDaoTokens(contributionBeforeFee);
        }
    }

    function _mintDaoTokens(uint256 _contributionBeforeFee) internal returns (uint256 mintAmount_) {
        // Mint needed DAO Tokens
        NewReserve memory _newReserve = takasureReserve.getReserveValues();
        mintAmount_ = _contributionBeforeFee * DECIMALS_PRECISION; // 6 decimals to 18 decimals

        bool success = ITSToken(_newReserve.daoToken).mint(address(takasureReserve), mintAmount_);
        if (!success) {
            revert TakasureErrors.TakasurePool__MintFailed();
        }
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(TAKADAO_OPERATOR) {}
}
