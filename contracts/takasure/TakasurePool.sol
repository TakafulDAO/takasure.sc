//SPDX-License-Identifier: GPL-3.0

/**
 * @title TakasurePool
 * @author Maikel Ordaz
 * @dev Users communicate with this module to become members of the DAO. It contains member management
 *      functionality such as modifying or canceling the policy, updates BM and BMA, remove non active
 *      members, calculate surplus
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBenefitMultiplierConsumer} from "contracts/interfaces/IBenefitMultiplierConsumer.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {TSToken} from "contracts/token/TSToken.sol";

import {Reserve, Member, MemberState, RevenueType} from "contracts/types/TakasureTypes.sol";
import {ReserveMathLib} from "contracts/libraries/ReserveMathLib.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {TakasureErrors} from "contracts/libraries/TakasureErrors.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

pragma solidity 0.8.25;

contract TakasurePool is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    IERC20 private contributionToken;
    TSToken private daoToken;
    IBenefitMultiplierConsumer private bmConsumer;

    Reserve private reserve;

    bytes32 private constant TAKADAO_OPERATOR = keccak256("TAKADAO_OPERATOR");
    bytes32 private constant DAO_MULTISIG = keccak256("DAO_MULTISIG");
    bytes32 private constant KYC_PROVIDER = keccak256("KYC_PROVIDER");
    bytes32 private constant PAUSE_GUARDIAN = keccak256("PAUSE_GUARDIAN");

    uint256 private constant DECIMALS_PRECISION = 1e12;
    uint256 private constant DECIMAL_REQUIREMENT_PRECISION_USDC = 1e4; // 4 decimals to receive at minimum 0.01 USDC
    uint256 private constant DEFAULT_MEMBERSHIP_DURATION = 5 * (365 days); // 5 year
    uint256 private constant MONTH = 30 days; // Todo: manage a better way for 365 days and leap years maybe?
    uint256 private constant DAY = 1 days;
    uint256 private constant INITIAL_RESERVE_RATIO = 40; // 40% Default

    bool private allowCustomDuration; // while false, the membership duration is fixed to 5 years
    bool private isOptimizerEnabled; // Default true
    uint8 private riskMultiplier; // Default to 2%
    uint8 private bmaFundReserveShare; // Default 70%
    uint8 private fundMarketExpendsAddShare; // Default 20%

    uint256 private dayDepositTimestamp; // 0 at begining, then never is zero again
    uint256 private monthDepositTimestamp; // 0 at begining, then never is zero again
    uint16 private monthReference; // Will count the month. For gas issues will grow undefinitely
    uint8 private dayReference; // Will count the day of the month from 1 -> 30, then resets to 1

    uint256 private minimumThreshold;
    uint256 private maximumThreshold;
    uint256 private memberIdCounter;
    address private feeClaimAddress;

    uint256 private RPOOL; // todo: define this value

    mapping(address member => Member) private members;
    mapping(uint256 memberIdCounter => address memberWallet) private idToMemberWallet;

    mapping(uint16 month => uint256 montCashFlow) private monthToCashFlow;
    mapping(uint16 month => mapping(uint8 day => uint256 dayCashFlow)) private dayToCashFlow; // ? Maybe better block.timestamp => dailyDeposits for this one?

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param _contributionToken default USDC
     * @param _feeClaimAddress address allowed to claim the service fee
     * @param _daoOperator address allowed to manage the DAO
     * @dev it reverts if any of the addresses is zero
     */
    function initialize(
        address _contributionToken,
        address _feeClaimAddress,
        address _daoOperator,
        address _takadaoOperator,
        address _kycProvider,
        address _pauseGuardian,
        address _tokenAdmin,
        string memory _tokenName,
        string memory _tokenSymbol
    ) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _daoOperator);
        _grantRole(TAKADAO_OPERATOR, _takadaoOperator);
        _grantRole(DAO_MULTISIG, _daoOperator);
        _grantRole(KYC_PROVIDER, _kycProvider);
        _grantRole(PAUSE_GUARDIAN, _pauseGuardian);

        contributionToken = IERC20(_contributionToken);
        daoToken = new TSToken(_tokenAdmin, _tokenName, _tokenSymbol);
        feeClaimAddress = _feeClaimAddress;

        monthReference = 1;
        dayReference = 1;
        minimumThreshold = 25e6; // 25 USDC // 6 decimals
        maximumThreshold = 250e6; // 250 USDC // 6 decimals

        reserve.dynamicReserveRatio = INITIAL_RESERVE_RATIO; // Default
        reserve.benefitMultiplierAdjuster = 100; // 100% Default
        reserve.serviceFee = 22; // 22% of the contribution amount. Default
        fundMarketExpendsAddShare = 20; // 20% Default
        bmaFundReserveShare = 70; // 70% Default
        riskMultiplier = 2; // 2% Default
        isOptimizerEnabled = true; // Default

        emit TakasureEvents.OnInitialReserveValues(
            INITIAL_RESERVE_RATIO,
            reserve.dynamicReserveRatio,
            reserve.benefitMultiplierAdjuster,
            reserve.serviceFee,
            bmaFundReserveShare,
            isOptimizerEnabled,
            address(contributionToken),
            address(daoToken)
        );
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
    function joinPool(uint256 contributionBeforeFee, uint256 membershipDuration) external {
        if (members[msg.sender].memberState != MemberState.Inactive) {
            revert TakasureErrors.TakasurePool__WrongMemberState();
        }
        if (contributionBeforeFee < minimumThreshold || contributionBeforeFee > maximumThreshold) {
            revert TakasureErrors.TakasurePool__WrongInput();
        }

        bool isKYCVerified = members[msg.sender].isKYCVerified;
        bool isRefunded = members[msg.sender].isRefunded;

        // Fetch the BM from the oracle
        uint256 benefitMultiplier = _getBenefitMultiplierFromOracle(msg.sender);

        (
            uint256 normalizedContributionBeforeFee,
            uint256 feeAmount,
            uint256 contributionAfterFee
        ) = _calculateAmountAndFees(contributionBeforeFee);

        if (isKYCVerified) {
            // Flow 1 KYC -> Join
            // It means the user is already in the system, we just need to update the values
            _updateMember({
                _benefitMultiplier: benefitMultiplier, // Will be fetched from off-chain oracle
                _contributionBeforeFee: normalizedContributionBeforeFee, // From the input
                _membershipDuration: membershipDuration, // From the input
                _feeAmount: feeAmount, // Calculated
                _memberWallet: msg.sender, // The member wallet
                _memberState: MemberState.Active, // Active state as it is already KYCed and paid the contribution
                _isKYCVerified: isKYCVerified, // The current state, does not change here
                _isRefunded: false // Reset to false as the user repays the contribution
            });

            // And we pay the contribution
            _memberPaymentFlow(
                normalizedContributionBeforeFee,
                contributionAfterFee,
                feeAmount,
                msg.sender,
                true
            );

            emit TakasureEvents.OnMemberJoined(members[msg.sender].memberId, msg.sender);
        } else {
            if (!isRefunded) {
                // Flow 2 Join -> KYC
                if (members[msg.sender].wallet != address(0)) {
                    revert TakasureErrors.TakasurePool__WrongMemberState();
                }
                // If is not KYC verified, and not refunded, it is a completele new member, we create it
                _createNewMember({
                    _benefitMultiplier: benefitMultiplier, // Fetch from oracle
                    _contributionBeforeFee: normalizedContributionBeforeFee, // From the input
                    _membershipDuration: membershipDuration, // From the input
                    _feeAmount: feeAmount, // Calculated
                    _isKYCVerified: isKYCVerified, // The current state, in this case false
                    _memberWallet: msg.sender, // The member wallet
                    _memberState: MemberState.Inactive // Set to inactive until the KYC is verified
                });
            } else {
                // Flow 3 Refund -> Join
                // If is not KYC verified, but refunded, the member exist already, but was previously refunded
                _updateMember({
                    _benefitMultiplier: benefitMultiplier,
                    _contributionBeforeFee: normalizedContributionBeforeFee, // From the input
                    _membershipDuration: membershipDuration, // From the input
                    _feeAmount: feeAmount, // Calculated
                    _memberWallet: msg.sender, // The member wallet
                    _memberState: MemberState.Inactive, // Set to inactive until the KYC is verified
                    _isKYCVerified: isKYCVerified, // The current state, in this case false
                    _isRefunded: false // Reset to false as the user repays the contribution
                });
            }

            // The member will pay the contribution, but will remain inactive until the KYC is verified
            // This means the proformas wont be updated, the amounts wont be added to the reserves,
            // the cash flow mappings wont change, the DRR and BMA wont be updated, the tokens wont be minted
            _transferAmounts(contributionAfterFee, feeAmount, msg.sender);
        }
    }

    /**
     * @notice Set the KYC status of a member. If the member does not exist, it will be created as inactive
     *         until the contribution is paid with joinPool. If the member has already joined the pool, then
     *         the contribution will be paid and the member will be active.
     * @param memberWallet address of the member
     * @dev It reverts if the member is the zero address
     * @dev It reverts if the member is already KYCed
     */
    function setKYCStatus(address memberWallet) external onlyRole(KYC_PROVIDER) {
        if (memberWallet == address(0)) {
            revert TakasureErrors.TakasurePool__ZeroAddress();
        }
        if (members[memberWallet].isKYCVerified) {
            revert TakasureErrors.TakasurePool__WrongMemberState();
        }

        bool isRefunded = members[memberWallet].isRefunded;

        // Fetch the BM from the oracle
        uint256 benefitMultiplier = _getBenefitMultiplierFromOracle(memberWallet);

        if (members[memberWallet].wallet == address(0)) {
            // Flow 1 KYC -> Join
            // This means the user does not exist yet
            _createNewMember({
                _benefitMultiplier: benefitMultiplier,
                _contributionBeforeFee: 0, // We dont know it yet
                _membershipDuration: 0, // We dont know it yet
                _feeAmount: 0, // We dont know it yet
                _isKYCVerified: true, // Set to true with this call
                _memberWallet: memberWallet, // The member wallet
                _memberState: MemberState.Inactive // Set to inactive until the contribution is paid
            });
        } else {
            if (!isRefunded) {
                // Flow 2 Join -> KYC
                // This means the user exists and payed contribution but is not KYCed yet, we update the values
                (
                    uint256 normalizedContributionBeforeFee,
                    uint256 feeAmount,
                    uint256 contributionAfterFee
                ) = _calculateAmountAndFees(members[memberWallet].contribution);

                _updateMember({
                    _benefitMultiplier: benefitMultiplier, // We take the current value
                    _contributionBeforeFee: normalizedContributionBeforeFee, // We take the current value
                    _membershipDuration: members[memberWallet].membershipDuration, // We take the current value
                    _feeAmount: feeAmount, // Calculated
                    _memberWallet: memberWallet, // The member wallet
                    _memberState: MemberState.Active, // Active state as the user is already paid the contribution and KYCed
                    _isKYCVerified: true, // Set to true with this call
                    _isRefunded: false // Remains false as the user is not refunded
                });

                // Then the everyting needed will be updated, proformas, reserves, cash flow,
                // DRR, BMA, tokens minted, no need to transfer the amounts as they are already paid
                _memberPaymentFlow(
                    normalizedContributionBeforeFee,
                    contributionAfterFee,
                    feeAmount,
                    memberWallet,
                    false
                );

                emit TakasureEvents.OnMemberJoined(members[memberWallet].memberId, memberWallet);
            } else {
                // Flow 4 Refund -> KYC
                // This means the user exists, but was refunded, we reset the values
                _updateMember({
                    _benefitMultiplier: benefitMultiplier, // As the B, does not change, we can avoid re-fetching
                    _contributionBeforeFee: 0, // Reset until the user pays the contribution
                    _membershipDuration: 0, // Reset until the user pays the contribution
                    _feeAmount: 0, // Reset until the user pays the contribution
                    _memberWallet: memberWallet, // The member wallet
                    _memberState: MemberState.Inactive, // Set to inactive until the contribution is paid
                    _isKYCVerified: true, // Set to true with this call
                    _isRefunded: true // Remains true until the user pays the contribution
                });
            }
        }
        emit TakasureEvents.OnMemberKycVerified(members[memberWallet].memberId, memberWallet);
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
        if (memberWallet == address(0)) {
            revert TakasureErrors.TakasurePool__ZeroAddress();
        }
        _refund(memberWallet);
    }

    function recurringPayment() external {
        if (members[msg.sender].memberState != MemberState.Active) {
            revert TakasureErrors.TakasurePool__WrongMemberState();
        }
        uint256 currentTimestamp = block.timestamp;
        uint256 membershipStartTime = members[msg.sender].membershipStartTime;
        uint256 membershipDuration = members[msg.sender].membershipDuration;
        uint256 lastPaidYearStartDate = members[msg.sender].lastPaidYearStartDate;
        uint256 year = 365 days;
        uint256 gracePeriod = 30 days;

        if (
            currentTimestamp > lastPaidYearStartDate + year + gracePeriod ||
            currentTimestamp > membershipStartTime + membershipDuration
        ) {
            revert TakasureErrors.TakasurePool__InvalidDate();
        }

        uint256 contributionBeforeFee = members[msg.sender].contribution;
        uint256 feeAmount = (contributionBeforeFee * reserve.serviceFee) / 100;
        uint256 contributionAfterFee = contributionBeforeFee - feeAmount;

        // Update the values
        members[msg.sender].lastPaidYearStartDate += 365 days;
        members[msg.sender].totalContributions += contributionBeforeFee;
        members[msg.sender].totalServiceFee += feeAmount;
        members[msg.sender].lastEcr = 0;
        members[msg.sender].lastUcr = 0;

        // And we pay the contribution
        _memberPaymentFlow(
            contributionBeforeFee,
            feeAmount,
            contributionAfterFee,
            msg.sender,
            true
        );

        emit TakasureEvents.OnRecurringPayment(
            msg.sender,
            members[msg.sender].memberId,
            members[msg.sender].lastPaidYearStartDate,
            members[msg.sender].totalContributions,
            members[msg.sender].totalServiceFee
        );
    }

    /**
     * @notice To be called by the DAO to update the Fund reserve with new revenues
     * @param newRevenue the new revenue to be added to the fund reserve
     * @param revenueType the type of revenue to be added
     */
    function depositRevenue(
        uint256 newRevenue,
        RevenueType revenueType
    ) external onlyRole(DAO_MULTISIG) {
        if (revenueType == RevenueType.Contribution) {
            revert TakasureErrors.TakasurePool__WrongInput();
        }
        _updateRevenue(newRevenue, revenueType);
        _updateCashMappings(newRevenue);
        reserve.totalFundReserve += newRevenue;

        bool success = contributionToken.transferFrom(msg.sender, address(this), newRevenue);
        if (!success) {
            revert TakasureErrors.TakasurePool__TransferFailed();
        }
    }

    function setNewBenefitMultiplierConsumer(address newBenefitMultiplierConsumer) external {
        if (newBenefitMultiplierConsumer == address(0)) {
            revert TakasureErrors.TakasurePool__ZeroAddress();
        }
        if (!hasRole(TAKADAO_OPERATOR, msg.sender) && !hasRole(DAO_MULTISIG, msg.sender)) {
            revert TakasureErrors.OnlyDaoOrTakadao();
        }

        address oldBenefitMultiplierConsumer = address(bmConsumer);
        bmConsumer = IBenefitMultiplierConsumer(newBenefitMultiplierConsumer);

        emit TakasureEvents.OnBenefitMultiplierConsumerChanged(
            newBenefitMultiplierConsumer,
            oldBenefitMultiplierConsumer
        );
    }

    function getReserveValues() external view returns (Reserve memory) {
        return reserve;
    }

    function getMemberFromAddress(address member) external view returns (Member memory) {
        return members[member];
    }

    /**
     * @notice Get the cash flow for the last 12 months. From the time is called
     * @return cash_ the cash flow for the last 12 months
     */
    function getCashLast12Months() external view returns (uint256 cash_) {
        (uint16 monthFromCall, uint8 dayFromCall) = _monthAndDayFromCall();
        cash_ = _cashLast12Months(monthFromCall, dayFromCall);
    }

    function _refund(address _memberWallet) internal {
        // The member should not be KYCed neither already refunded
        if (members[_memberWallet].isKYCVerified == true) {
            revert TakasureErrors.TakasurePool__WrongMemberState();
        }
        if (members[_memberWallet].isRefunded == true) {
            revert TakasureErrors.TakasurePool__NothingToRefund();
        }
        uint256 currentTimestamp = block.timestamp;
        uint256 membershipStartTime = members[_memberWallet].membershipStartTime;
        // The member can refund after 14 days of the payment
        uint256 limitTimestamp = membershipStartTime + (14 days);
        if (currentTimestamp < limitTimestamp) {
            revert TakasureErrors.TakasurePool__InvalidDate();
        }
        // No need to check if contribution amounnt is 0, as the member only is created with the contribution 0
        // when first KYC and then join the pool. So the previous check is enough

        // As there is only one contribution, is easy to calculte with the Member struct values
        uint256 contributionAmount = members[_memberWallet].contribution;
        uint256 serviceFeeAmount = members[_memberWallet].totalServiceFee;
        uint256 amountToRefund = contributionAmount - serviceFeeAmount;

        // Update the member values
        members[_memberWallet].isRefunded = true;

        // Transfer the amount to refund
        bool success = contributionToken.transfer(_memberWallet, amountToRefund);
        if (!success) {
            revert TakasureErrors.TakasurePool__TransferFailed();
        }

        emit TakasureEvents.OnRefund(
            members[_memberWallet].memberId,
            _memberWallet,
            amountToRefund
        );
    }

    function _calculateAmountAndFees(
        uint256 _contributionBeforeFee
    )
        internal
        view
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
        feeAmount_ = (normalizedContributionBeforeFee_ * reserve.serviceFee) / 100;
        contributionAfterFee_ = normalizedContributionBeforeFee_ - feeAmount_;
    }

    function _createNewMember(
        uint256 _benefitMultiplier,
        uint256 _contributionBeforeFee,
        uint256 _membershipDuration,
        uint256 _feeAmount,
        bool _isKYCVerified,
        address _memberWallet,
        MemberState _memberState
    ) internal {
        ++memberIdCounter;
        uint256 currentTimestamp = block.timestamp;
        uint256 userMembershipDuration;

        if (allowCustomDuration) {
            userMembershipDuration = _membershipDuration;
        } else {
            userMembershipDuration = DEFAULT_MEMBERSHIP_DURATION;
        }

        uint256 contributionAfterFee = _contributionBeforeFee - _feeAmount;
        uint256 claimAddAmount = (contributionAfterFee * (100 - reserve.dynamicReserveRatio)) / 100;

        Member memory newMember = Member({
            memberId: memberIdCounter,
            benefitMultiplier: _benefitMultiplier,
            membershipDuration: userMembershipDuration,
            membershipStartTime: currentTimestamp,
            lastPaidYearStartDate: currentTimestamp,
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

        // Add the member to the corresponding mappings
        members[_memberWallet] = newMember;
        idToMemberWallet[memberIdCounter] = _memberWallet;

        emit TakasureEvents.OnMemberCreated(
            memberIdCounter,
            _memberWallet,
            _benefitMultiplier,
            _contributionBeforeFee,
            _feeAmount,
            userMembershipDuration,
            currentTimestamp
        );
    }

    function _updateMember(
        uint256 _benefitMultiplier,
        uint256 _contributionBeforeFee,
        uint256 _membershipDuration,
        uint256 _feeAmount,
        address _memberWallet,
        MemberState _memberState,
        bool _isKYCVerified,
        bool _isRefunded
    ) internal {
        uint256 currentTimestamp = block.timestamp;
        uint256 userMembershipDuration;
        uint256 contributionAfterFee = _contributionBeforeFee - _feeAmount;
        uint256 claimAddAmount = (contributionAfterFee * (100 - reserve.dynamicReserveRatio)) / 100;

        if (allowCustomDuration) {
            userMembershipDuration = _membershipDuration;
        } else {
            userMembershipDuration = DEFAULT_MEMBERSHIP_DURATION;
        }

        members[_memberWallet].benefitMultiplier = _benefitMultiplier;
        members[_memberWallet].membershipDuration = userMembershipDuration;
        members[_memberWallet].membershipStartTime = currentTimestamp;
        members[_memberWallet].contribution = _contributionBeforeFee;
        members[_memberWallet].claimAddAmount = claimAddAmount;
        members[_memberWallet].totalServiceFee = _feeAmount;
        members[_memberWallet].memberState = _memberState;
        members[_memberWallet].isKYCVerified = _isKYCVerified;
        members[_memberWallet].isRefunded = _isRefunded;

        emit TakasureEvents.OnMemberUpdated(
            members[_memberWallet].memberId,
            _memberWallet,
            _benefitMultiplier,
            _contributionBeforeFee,
            _feeAmount,
            userMembershipDuration,
            currentTimestamp
        );
    }

    /**
     * @notice This function will update all the variables needed when a member pays the contribution
     * @param _payContribution true -> the contribution will be paid and the credit tokens will be minted
     *                                      false -> no need to pay the contribution as it is already payed
     */
    function _memberPaymentFlow(
        uint256 _contributionBeforeFee,
        uint256 _contributionAfterFee,
        uint256 _feeAmount,
        address _memberWallet,
        bool _payContribution
    ) internal {
        _getBenefitMultiplierFromOracle(_memberWallet);
        _updateProFormas(_contributionAfterFee, _contributionBeforeFee);
        _updateReserves(_contributionBeforeFee, _contributionAfterFee);
        _updateCashMappings(_contributionAfterFee);
        uint256 cashLast12Months = _cashLast12Months(monthReference, dayReference);
        _updateDRR(cashLast12Months);
        _updateBMA(cashLast12Months);
        _updateLossRatio(reserve.totalFundCost, reserve.totalFundRevenues);
        _mintDaoTokens(_contributionBeforeFee, _memberWallet);
        // update ucrisk calculation ratio
        _memberSurplus();
        if (_payContribution) {
            _transferAmounts(_contributionAfterFee, _feeAmount, _memberWallet);
        }
    }

    function _getBenefitMultiplierFromOracle(
        address _member
    ) internal returns (uint256 benefitMultiplier_) {
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
                members[_member].benefitMultiplier = benefitMultiplier_;
            } else {
                // If failed we get the error and revert with it
                bytes memory errorResponse = bmConsumer.idToErrorResponse(requestId);
                revert TakasureErrors.TakasurePool__BenefitMultiplierRequestFailed(errorResponse);
            }
        }
    }

    function _updateProFormas(
        uint256 _contributionAfterFee,
        uint256 _contributionBeforeFee
    ) internal {
        // Scope to avoid stack too deep error. This scope update both pro formas
        uint256 updatedProFormaFundReserve = ReserveMathLib._updateProFormaFundReserve(
            reserve.proFormaFundReserve,
            _contributionAfterFee,
            INITIAL_RESERVE_RATIO
        );

        uint256 updatedProFormaClaimReserve = ReserveMathLib._updateProFormaClaimReserve(
            reserve.proFormaClaimReserve,
            _contributionBeforeFee,
            reserve.serviceFee,
            INITIAL_RESERVE_RATIO
        );

        reserve.proFormaFundReserve = updatedProFormaFundReserve;
        reserve.proFormaClaimReserve = updatedProFormaClaimReserve;

        emit TakasureEvents.OnNewProFormaValues(
            updatedProFormaFundReserve,
            updatedProFormaClaimReserve
        );
    }

    function _updateReserves(
        uint256 _contributionBeforeFee,
        uint256 _contributionAfterFee
    ) internal {
        uint256 toFundReserveBeforeExpenditures = (_contributionAfterFee *
            reserve.dynamicReserveRatio) / 100;

        uint256 marketExpenditure = (toFundReserveBeforeExpenditures * fundMarketExpendsAddShare) /
            100;

        uint256 toFundReserve = toFundReserveBeforeExpenditures - marketExpenditure;
        uint256 toClaimReserve = _contributionAfterFee - toFundReserveBeforeExpenditures;

        reserve.totalFundReserve += toFundReserve;
        reserve.totalClaimReserve += toClaimReserve;
        reserve.totalContributions += _contributionBeforeFee;

        reserve.totalFundCost += marketExpenditure;
        reserve.totalFundRevenues = _updateRevenue(_contributionAfterFee, RevenueType.Contribution);

        emit TakasureEvents.OnNewReserveValues(
            reserve.totalContributions,
            reserve.totalClaimReserve,
            reserve.totalFundReserve,
            reserve.totalFundCost
        );
    }

    function _updateLossRatio(uint256 _totalFundCost, uint256 _totalFundRevenues) internal {
        reserve.lossRatio = ReserveMathLib._calculateLossRatio(_totalFundCost, _totalFundRevenues);
        emit TakasureEvents.OnNewLossRatio(reserve.lossRatio);
    }

    /**
     * @notice Update the fund reserve with the external revenue
     * @param _newRevenue the new revenue to be added to the fund reserve
     * @param _revenueType the type of revenue to be added. Six decimals
     * @return totalRevenues_ the total revenues in the fund reserve
     */
    function _updateRevenue(
        uint256 _newRevenue,
        RevenueType _revenueType
    ) internal returns (uint256 totalRevenues_) {
        reserve.totalFundRevenues += _newRevenue;
        totalRevenues_ = reserve.totalFundRevenues;

        emit TakasureEvents.OnExternalRevenue(_newRevenue, totalRevenues_, _revenueType);
    }

    function _updateCashMappings(uint256 _cashIn) internal {
        uint256 currentTimestamp = block.timestamp;

        if (dayDepositTimestamp == 0 && monthDepositTimestamp == 0) {
            // If the depositTimestamp is 0 it means it is the first deposit
            // Set the initial values for future calculations and reference
            dayDepositTimestamp = currentTimestamp;
            monthDepositTimestamp = currentTimestamp;
            monthToCashFlow[monthReference] = _cashIn;
            dayToCashFlow[monthReference][dayReference] = _cashIn;
        } else {
            // Check how many days and months have passed since the last deposit
            uint256 daysPassed = ReserveMathLib._calculateDaysPassed(
                currentTimestamp,
                dayDepositTimestamp
            );
            uint256 monthsPassed = ReserveMathLib._calculateMonthsPassed(
                currentTimestamp,
                monthDepositTimestamp
            );

            if (monthsPassed == 0) {
                // If no months have passed, update the mapping for the current month
                monthToCashFlow[monthReference] += _cashIn;
                if (daysPassed == 0) {
                    // If no days have passed, update the mapping for the current day
                    dayToCashFlow[monthReference][dayReference] += _cashIn;
                } else {
                    // If it is a new day, update the day deposit timestamp and the new day reference
                    dayDepositTimestamp += daysPassed * DAY;
                    dayReference += uint8(daysPassed);

                    // Update the mapping for the new day
                    dayToCashFlow[monthReference][dayReference] = _cashIn;
                }
            } else {
                // If it is a new month, update the month deposit timestamp and the day deposit timestamp
                // both should be the same as it is a new month
                monthDepositTimestamp += monthsPassed * MONTH;
                dayDepositTimestamp = monthDepositTimestamp;
                // Update the month reference to the corresponding month
                monthReference += uint16(monthsPassed);
                // Calculate the day reference for the new month, we need to recalculate the days passed
                // with the new day deposit timestamp
                daysPassed = ReserveMathLib._calculateDaysPassed(
                    currentTimestamp,
                    dayDepositTimestamp
                );
                // The new day reference is the days passed + initial day. Initial day refers
                // to the first day of the month
                uint8 initialDay = 1;
                dayReference = uint8(daysPassed) + initialDay;

                // Update the mappings for the new month and day
                monthToCashFlow[monthReference] = _cashIn;
                dayToCashFlow[monthReference][dayReference] = _cashIn;
            }
        }
    }

    function _cashLast12Months(
        uint16 _currentMonth,
        uint8 _currentDay
    ) internal view returns (uint256 cashLast12Months_) {
        uint256 cash = 0;

        // Then make the iterations, according the month and day this function is called
        if (_currentMonth < 13) {
            // Less than a complete year, iterate through every month passed
            // Return everything stored in the mappings until now
            for (uint8 i = 1; i <= _currentMonth; ) {
                cash += monthToCashFlow[i];

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
                cash += monthToCashFlow[monthBackCounter];

                unchecked {
                    ++i;
                }
            }

            // Iterate an extra month to complete the days that are left from the current month
            uint16 extraMonthToCheck = _currentMonth - monthsInYear;
            uint8 dayBackCounter = 30;
            uint8 extraDaysToCheck = dayBackCounter - _currentDay;

            for (uint8 i; i < extraDaysToCheck; ) {
                cash += dayToCashFlow[extraMonthToCheck][dayBackCounter];

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
        uint256 currentTimestamp = block.timestamp;
        uint256 lastDayDepositTimestamp = dayDepositTimestamp;
        uint256 lastMonthDepositTimestamp = monthDepositTimestamp;

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
            currentMonth_ = monthReference;
            if (daysPassed == 0) {
                // If no days have passed, current day is the reference
                currentDay_ = dayReference;
            } else {
                // If you are in a new day, calculate the days passed
                currentDay_ = uint8(daysPassed) + dayReference;
            }
        } else {
            // If you are in a new month, calculate the months passed
            currentMonth_ = uint16(monthsPassed) + monthReference;
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

    function _updateDRR(uint256 _cash) internal {
        uint256 updatedDynamicReserveRatio = ReserveMathLib._calculateDynamicReserveRatio(
            INITIAL_RESERVE_RATIO,
            reserve.proFormaFundReserve,
            reserve.totalFundReserve,
            _cash
        );

        reserve.dynamicReserveRatio = updatedDynamicReserveRatio;

        emit TakasureEvents.OnNewDynamicReserveRatio(updatedDynamicReserveRatio);
    }

    function _updateBMA(uint256 _cash) internal {
        uint256 bmaInflowAssumption = ReserveMathLib._calculateBmaInflowAssumption(
            _cash,
            reserve.serviceFee,
            INITIAL_RESERVE_RATIO
        );

        uint256 updatedBMA = ReserveMathLib._calculateBmaCashFlowMethod(
            reserve.totalClaimReserve,
            reserve.totalFundReserve,
            bmaFundReserveShare,
            reserve.proFormaClaimReserve,
            bmaInflowAssumption
        );

        reserve.benefitMultiplierAdjuster = updatedBMA;

        emit TakasureEvents.OnNewBenefitMultiplierAdjuster(updatedBMA);
    }

    function _transferAmounts(
        uint256 _contributionAfterFee,
        uint256 _feeAmount,
        address _memberWallet
    ) internal {
        bool success;

        // Transfer the contribution to the pool
        success = contributionToken.transferFrom(
            _memberWallet,
            address(this),
            _contributionAfterFee
        );
        if (!success) {
            revert TakasureErrors.TakasurePool__TransferFailed();
        }

        // Transfer the service fee to the fee claim address
        success = contributionToken.transferFrom(_memberWallet, feeClaimAddress, _feeAmount);
        if (!success) {
            revert TakasureErrors.TakasurePool__TransferFailed();
        }
    }

    function _mintDaoTokens(uint256 _contributionBeforeFee, address _memberWallet) internal {
        // Mint needed DAO Tokens
        uint256 mintAmount = _contributionBeforeFee * DECIMALS_PRECISION; // 6 decimals to 18 decimals
        members[_memberWallet].creditTokensBalance = mintAmount;

        bool success = daoToken.mint(address(this), mintAmount);
        if (!success) {
            revert TakasureErrors.TakasurePool__MintFailed();
        }
    }

    /**
     * @notice Calculate the total earned and unearned contribution reserves for all active members
     * @dev It does not count the recently added member
     * @dev It updates the total earned and unearned contribution reserves every time it is called
     * @dev Members in the grace period are not considered
     * @return totalECRes_ the total earned contribution reserve. Six decimals
     * @return totalUCRes_ the total unearned contribution reserve. Six decimals
     */
    // Todo: This will need another approach to avoid DoS, for now it is mainly to be able to test the algorithm
    function _totalECResAndUCResUnboundedLoop()
        internal
        returns (uint256 totalECRes_, uint256 totalUCRes_)
    {
        uint256 newECRes;
        // We check for every member except the recently added
        for (uint256 i = 1; i <= memberIdCounter - 1; ) {
            address memberWallet = idToMemberWallet[i];
            Member storage memberToCheck = members[memberWallet];
            if (memberToCheck.memberState == MemberState.Active) {
                (uint256 memberEcr, uint256 memberUcr) = ReserveMathLib._calculateEcrAndUcrByMember(
                    memberToCheck
                );

                newECRes += memberEcr;
                totalUCRes_ += memberUcr;
            }

            unchecked {
                ++i;
            }
        }

        reserve.ECRes = newECRes;
        reserve.UCRes = totalUCRes_;

        totalECRes_ = reserve.ECRes;
    }

    /**
     * @notice Surplus to be distributed among the members
     * @return surplus_ in six decimals
     */
    function _calculateSurplus() internal returns (uint256 surplus_) {
        (uint256 totalECRes, uint256 totalUCRes) = _totalECResAndUCResUnboundedLoop();
        uint256 UCRisk;

        UCRisk = (totalUCRes * riskMultiplier) / 100;

        // surplus = max(0, ECRes - max(0, UCRisk - UCRes -  RPOOL))
        surplus_ = uint256(
            ReserveMathLib._maxInt(
                0,
                (int256(totalECRes) -
                    ReserveMathLib._maxInt(
                        0,
                        (int256(UCRisk) - int256(totalUCRes) - int256(RPOOL))
                    ))
            )
        );

        reserve.surplus = surplus_;

        emit TakasureEvents.OnFundSurplusUpdated(surplus_);
    }

    /**
     * @notice Calculate the surplus for a member
     */
    function _memberSurplus() internal {
        uint256 totalSurplus = _calculateSurplus();
        uint256 userCreditTokensBalance = members[msg.sender].creditTokensBalance;
        uint256 totalCreditTokens = daoToken.balanceOf(address(this));
        uint256 userSurplus = (totalSurplus * userCreditTokensBalance) / totalCreditTokens;
        members[msg.sender].memberSurplus = userSurplus;
        emit TakasureEvents.OnMemberSurplusUpdated(members[msg.sender].memberId, userSurplus);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DAO_MULTISIG) {}
}
