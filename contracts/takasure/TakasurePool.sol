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
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {TSToken} from "contracts/token/TSToken.sol";

import {Reserve, Member, MemberState} from "contracts/types/TakasureTypes.sol";
import {ReserveMathLib} from "contracts/libraries/ReserveMathLib.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {TakasureErrors} from "contracts/libraries/TakasureErrors.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

pragma solidity 0.8.25;

contract TakasurePool is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardTransientUpgradeable
{
    IERC20 private contributionToken;
    TSToken private daoToken;
    IBenefitMultiplierConsumer private bmConsumer;

    Reserve private reserve;

    bytes32 public constant TAKADAO_OPERATOR = keccak256("TAKADAO_OPERATOR");
    bytes32 public constant DAO_MULTISIG = keccak256("DAO_MULTISIG");
    bytes32 public constant KYC_PROVIDER = keccak256("KYC_PROVIDER");
    bytes32 public constant PAUSE_GUARDIAN = keccak256("PAUSE_GUARDIAN");

    uint256 private constant DECIMALS_PRECISION = 1e12;
    uint256 private constant DECIMAL_REQUIREMENT_PRECISION_USDC = 1e4; // 4 decimals to receive at minimum 0.01 USDC
    uint256 private constant DEFAULT_MEMBERSHIP_DURATION = 5 * (365 days); // 5 year
    uint256 private constant MONTH = 30 days; // Todo: manage a better way for 365 days and leap years maybe?
    uint256 private constant DAY = 1 days;
    uint256 public constant INITIAL_RESERVE_RATIO = 40; // 40% Default

    bool public allowCustomDuration; // while false, the membership duration is fixed to 5 years

    uint256 private dayDepositTimestamp; // 0 at begining, then never is zero again
    uint256 private monthDepositTimestamp; // 0 at begining, then never is zero again
    uint16 private monthReference; // Will count the month. For gas issues will grow undefinitely
    uint8 private dayReference; // Will count the day of the month from 1 -> 30, then resets to 1

    uint256 public minimumThreshold;
    uint256 public maximumThreshold;
    uint256 public memberIdCounter;
    address public feeClaimAddress;

    uint256 RPOOL; // todo: define this value

    mapping(uint256 memberIdCounter => Member) private idToMember;

    mapping(uint16 month => uint256 montCashFlow) private monthToCashFlow;
    mapping(uint16 month => mapping(uint8 day => uint256 dayCashFlow)) private dayToCashFlow; // ? Maybe better block.timestamp => dailyDeposits for this one?

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
        __ReentrancyGuardTransient_init();
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
        reserve.bmaFundReserveShare = 70; // 70% Default
        reserve.riskMultiplier = 2; // 2% Default
        reserve.isOptimizerEnabled = true; // Default

        emit TakasureEvents.OnInitialReserveValues(
            INITIAL_RESERVE_RATIO,
            reserve.dynamicReserveRatio,
            reserve.benefitMultiplierAdjuster,
            reserve.serviceFee,
            reserve.bmaFundReserveShare,
            reserve.isOptimizerEnabled,
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
    function joinPool(
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external nonReentrant {
        // Todo: Check the user benefit multiplier against the oracle.
        if (reserve.members[msg.sender].memberState == MemberState.Active) {
            revert TakasureErrors.TakasurePool__MemberAlreadyExists();
        }
        if (contributionBeforeFee < minimumThreshold || contributionBeforeFee > maximumThreshold) {
            revert TakasureErrors.TakasurePool__ContributionOutOfRange();
        }

        // Todo: re-calculate DAO Surplus.

        bool isKYCVerified = reserve.members[msg.sender].isKYCVerified;
        bool isRefunded = reserve.members[msg.sender].isRefunded;

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

            emit TakasureEvents.OnMemberJoined(reserve.members[msg.sender].memberId, msg.sender);
        } else {
            if (!isRefunded) {
                // Flow 2 Join -> KYC
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
        if (reserve.members[memberWallet].isKYCVerified) {
            revert TakasureErrors.TakasurePool__MemberAlreadyKYCed();
        }

        bool isRefunded = reserve.members[memberWallet].isRefunded;

        // Fetch the BM from the oracle
        uint256 benefitMultiplier = _getBenefitMultiplierFromOracle(memberWallet);

        if (reserve.members[memberWallet].wallet == address(0)) {
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
                ) = _calculateAmountAndFees(reserve.members[memberWallet].contribution);

                _updateMember({
                    _benefitMultiplier: benefitMultiplier, // We take the current value
                    _contributionBeforeFee: normalizedContributionBeforeFee, // We take the current value
                    _membershipDuration: reserve.members[memberWallet].membershipDuration, // We take the current value
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

                emit TakasureEvents.OnMemberJoined(
                    reserve.members[memberWallet].memberId,
                    memberWallet
                );
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
        emit TakasureEvents.OnMemberKycVerified(
            reserve.members[memberWallet].memberId,
            memberWallet
        );
    }

    /**
     * @notice Refunds the user unable to do KYC
     */
    function refund() external {
        // The member should not be KYCed neither already refunded
        if (reserve.members[msg.sender].isKYCVerified == true) {
            revert TakasureErrors.TakasurePool__MemberAlreadyKYCed();
        }
        if (reserve.members[msg.sender].isRefunded == true) {
            revert TakasureErrors.TakasurePool__NothingToRefund();
        }
        uint256 currentTimestamp = block.timestamp;
        uint256 membershipStartTime = reserve.members[msg.sender].membershipStartTime;
        // The member can refund after 14 days of the payment
        uint256 limitTimestamp = membershipStartTime + (14 days);
        if (currentTimestamp < limitTimestamp) {
            revert TakasureErrors.TakasurePool__TooEarlytoRefund();
        }
        // No need to check if contribution amounnt is 0, as the member only is created with the contribution 0
        // when first KYC and then join the pool. So the previous check is enough

        // As there is only one contribution, is easy to calculte with the Member struct values
        uint256 contributionAmount = reserve.members[msg.sender].contribution;
        uint256 serviceFeeAmount = reserve.members[msg.sender].totalServiceFee;
        uint256 amountToRefund = contributionAmount - serviceFeeAmount;

        // Transfer the amount to refund
        bool success = contributionToken.transfer(msg.sender, amountToRefund);
        if (!success) {
            revert TakasureErrors.TakasurePool__RefundFailed();
        }

        // Update the member values
        reserve.members[msg.sender].isRefunded = true;

        // ? Question: Should we update the other values? Or leave it like they are for some sort of history?

        emit TakasureEvents.OnRefund(
            reserve.members[msg.sender].memberId,
            msg.sender,
            amountToRefund
        );
    }

    function recurringPayment() external {
        if (reserve.members[msg.sender].memberState != MemberState.Active) {
            revert TakasureErrors.TakasurePool__WrongMemberState();
        }
        uint256 currentTimestamp = block.timestamp;
        uint256 yearsCovered = reserve.members[msg.sender].yearsCovered;
        uint256 membershipStartTime = reserve.members[msg.sender].membershipStartTime;
        uint256 membershipDuration = reserve.members[msg.sender].membershipDuration;

        if (
            currentTimestamp > membershipStartTime + ((yearsCovered) * 365 days) ||
            currentTimestamp > membershipStartTime + membershipDuration
        ) {
            revert TakasureErrors.TakasurePool__InvalidDate();
        }

        uint256 contributionBeforeFee = reserve.members[msg.sender].contribution;
        uint256 feeAmount = (contributionBeforeFee * reserve.serviceFee) / 100;
        uint256 contributionAfterFee = contributionBeforeFee - feeAmount;

        // Update the values
        ++reserve.members[msg.sender].yearsCovered;
        reserve.members[msg.sender].totalContributions += contributionBeforeFee;
        reserve.members[msg.sender].totalServiceFee += feeAmount;

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
            reserve.members[msg.sender].memberId,
            reserve.members[msg.sender].yearsCovered,
            reserve.members[msg.sender].totalContributions,
            reserve.members[msg.sender].totalServiceFee
        );
    }

    function setNewServiceFee(uint8 newServiceFee) external onlyRole(TAKADAO_OPERATOR) {
        if (newServiceFee > 35) {
            revert TakasureErrors.TakasurePool__WrongServiceFee();
        }
        reserve.serviceFee = newServiceFee;

        emit TakasureEvents.OnServiceFeeChanged(newServiceFee);
    }

    function setNewMinimumThreshold(uint256 newMinimumThreshold) external onlyRole(DAO_MULTISIG) {
        minimumThreshold = newMinimumThreshold;

        emit TakasureEvents.OnNewMinimumThreshold(newMinimumThreshold);
    }

    function setMaximumThreshold(uint256 newMaximumThreshold) external onlyRole(DAO_MULTISIG) {
        maximumThreshold = newMaximumThreshold;

        emit TakasureEvents.OnNewMaximumThreshold(newMaximumThreshold);
    }

    function setNewContributionToken(
        address newContributionToken
    ) external onlyRole(DAO_MULTISIG) notZeroAddress(newContributionToken) {
        contributionToken = IERC20(newContributionToken);
    }

    function setNewFeeClaimAddress(
        address newFeeClaimAddress
    ) external onlyRole(TAKADAO_OPERATOR) notZeroAddress(newFeeClaimAddress) {
        feeClaimAddress = newFeeClaimAddress;
    }

    function setNewBenefitMultiplierConsumer(
        address newBenefitMultiplierConsumer
    )
        external
        onlyRole(DAO_MULTISIG)
        onlyRole(TAKADAO_OPERATOR)
        notZeroAddress(newBenefitMultiplierConsumer)
    {
        address oldBenefitMultiplierConsumer = address(bmConsumer);
        bmConsumer = IBenefitMultiplierConsumer(newBenefitMultiplierConsumer);

        emit TakasureEvents.OnBenefitMultiplierConsumerChanged(
            newBenefitMultiplierConsumer,
            oldBenefitMultiplierConsumer
        );
    }

    function setAllowCustomDuration(bool _allowCustomDuration) external onlyRole(DAO_MULTISIG) {
        allowCustomDuration = _allowCustomDuration;
    }

    function setNewPauseGuardian(address newPauseGuardian) external onlyRole(PAUSE_GUARDIAN) {
        _grantRole(PAUSE_GUARDIAN, newPauseGuardian);
        _revokeRole(PAUSE_GUARDIAN, msg.sender);
    }

    function getReserveValues()
        external
        view
        returns (
            uint256 initialReserveRatio_,
            uint256 dynamicReserveRatio_,
            uint256 benefitMultiplierAdjuster_,
            uint256 totalContributions_,
            uint256 totalClaimReserve_,
            uint256 totalFundReserve_,
            uint256 proFormaFundReserve_,
            uint256 proFormaClaimReserve_,
            uint256 lossRatio_,
            uint8 serviceFee_,
            uint8 bmaFundReserveShare_,
            bool isOptimizerEnabled_
        )
    {
        initialReserveRatio_ = INITIAL_RESERVE_RATIO;
        dynamicReserveRatio_ = reserve.dynamicReserveRatio;
        benefitMultiplierAdjuster_ = reserve.benefitMultiplierAdjuster;
        totalContributions_ = reserve.totalContributions;
        totalClaimReserve_ = reserve.totalClaimReserve;
        totalFundReserve_ = reserve.totalFundReserve;
        proFormaFundReserve_ = reserve.proFormaFundReserve;
        proFormaClaimReserve_ = reserve.proFormaClaimReserve;
        lossRatio_ = reserve.lossRatio;
        serviceFee_ = reserve.serviceFee;
        bmaFundReserveShare_ = reserve.bmaFundReserveShare;
        isOptimizerEnabled_ = reserve.isOptimizerEnabled;
    }

    function getMemberKYCStatus(address member) external view returns (bool isKYCVerified_) {
        isKYCVerified_ = reserve.members[member].isKYCVerified;
    }

    function getMemberFromId(uint256 memberId) external view returns (Member memory) {
        return idToMember[memberId];
    }

    function getMemberFromAddress(address member) external view returns (Member memory) {
        return reserve.members[member];
    }

    function getDaoTokenAddress() external view returns (address) {
        return address(daoToken);
    }

    function getContributionTokenAddress() external view returns (address contributionToken_) {
        contributionToken_ = address(contributionToken);
    }

    /**
     * @notice Get the cash flow for the last 12 months. From the time is called
     * @return cash_ the cash flow for the last 12 months
     */
    function getCashLast12Months() external view returns (uint256 cash_) {
        (uint16 monthFromCall, uint8 dayFromCall) = _monthAndDayFromCall();
        cash_ = _cashLast12Months(monthFromCall, dayFromCall);
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

        Member memory newMember = Member({
            memberId: memberIdCounter,
            benefitMultiplier: _benefitMultiplier,
            membershipDuration: userMembershipDuration,
            yearsCovered: 1,
            membershipStartTime: currentTimestamp,
            contribution: _contributionBeforeFee,
            claimAddAmount: (contributionAfterFee * (100 - reserve.dynamicReserveRatio)) / 100,
            totalContributions: _contributionBeforeFee,
            totalServiceFee: _feeAmount,
            creditTokensBalance: 0,
            wallet: _memberWallet,
            memberState: _memberState,
            memberSurplus: 0, // Todo
            isKYCVerified: _isKYCVerified,
            isRefunded: false,
            lastEcrTime: 0,
            lastEcr: 0,
            lastUcr: 0
        });

        // Add the member to the corresponding mappings
        reserve.members[_memberWallet] = newMember;
        idToMember[memberIdCounter] = newMember;

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

        if (allowCustomDuration) {
            userMembershipDuration = _membershipDuration;
        } else {
            userMembershipDuration = DEFAULT_MEMBERSHIP_DURATION;
        }

        reserve.members[_memberWallet].benefitMultiplier = _benefitMultiplier;
        reserve.members[_memberWallet].membershipDuration = userMembershipDuration;
        reserve.members[_memberWallet].membershipStartTime = currentTimestamp;
        reserve.members[_memberWallet].contribution = _contributionBeforeFee;
        reserve.members[_memberWallet].claimAddAmount =
            (contributionAfterFee * (100 - reserve.dynamicReserveRatio)) /
            100;
        reserve.members[_memberWallet].totalServiceFee = _feeAmount;
        reserve.members[_memberWallet].memberState = _memberState;
        reserve.members[_memberWallet].isKYCVerified = _isKYCVerified;
        reserve.members[_memberWallet].isRefunded = _isRefunded;

        emit TakasureEvents.OnMemberUpdated(
            reserve.members[_memberWallet].memberId,
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
                reserve.members[_member].benefitMultiplier = benefitMultiplier_;
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
        uint256 toFundReserve = (_contributionAfterFee * reserve.dynamicReserveRatio) / 100;
        uint256 toClaimReserve = _contributionAfterFee - toFundReserve;

        reserve.totalFundReserve += toFundReserve;
        reserve.totalContributions += _contributionBeforeFee;
        reserve.totalClaimReserve += toClaimReserve;

        emit TakasureEvents.OnNewReserveValues(
            reserve.totalContributions,
            reserve.totalClaimReserve,
            reserve.totalFundReserve
        );
    }

    function _updateCashMappings(uint256 _contributionAfterFee) internal {
        uint256 currentTimestamp = block.timestamp;

        if (dayDepositTimestamp == 0 && monthDepositTimestamp == 0) {
            // If the depositTimestamp is 0 it means it is the first deposit
            // Set the initial values for future calculations and reference
            dayDepositTimestamp = currentTimestamp;
            monthDepositTimestamp = currentTimestamp;
            monthToCashFlow[monthReference] = _contributionAfterFee;
            dayToCashFlow[monthReference][dayReference] = _contributionAfterFee;
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
                monthToCashFlow[monthReference] += _contributionAfterFee;
                if (daysPassed == 0) {
                    // If no days have passed, update the mapping for the current day
                    dayToCashFlow[monthReference][dayReference] += _contributionAfterFee;
                } else {
                    // If it is a new day, update the day deposit timestamp and the new day reference
                    dayDepositTimestamp += daysPassed * DAY;
                    dayReference += uint8(daysPassed);

                    // Update the mapping for the new day
                    dayToCashFlow[monthReference][dayReference] = _contributionAfterFee;
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
                monthToCashFlow[monthReference] = _contributionAfterFee;
                dayToCashFlow[monthReference][dayReference] = _contributionAfterFee;
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
            reserve.bmaFundReserveShare,
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
            revert TakasureErrors.TakasurePool__ContributionTransferFailed();
        }

        // Transfer the service fee to the fee claim address
        success = contributionToken.transferFrom(_memberWallet, feeClaimAddress, _feeAmount);
        if (!success) {
            revert TakasureErrors.TakasurePool__FeeTransferFailed();
        }
    }

    function _mintDaoTokens(uint256 _contributionBeforeFee, address _memberWallet) internal {
        // Mint needed DAO Tokens
        uint256 mintAmount = _contributionBeforeFee * DECIMALS_PRECISION; // 6 decimals to 18 decimals
        reserve.members[_memberWallet].creditTokensBalance = mintAmount;

        bool success = daoToken.mint(address(this), mintAmount);
        if (!success) {
            revert TakasureErrors.TakasurePool__MintFailed();
        }
    }

    function _pause() internal override whenNotPaused onlyRole(PAUSE_GUARDIAN) {
        super._pause();
    }

    function _unpause() internal override whenPaused onlyRole(PAUSE_GUARDIAN) {
        super._unpause();
    }

    /// @notice Calculate the total earned and unearned contribution reserves for all active members
    // Todo: This will need another approach to avoid DoS, for now it is mainly to be able to test the algorithm
    function _totalECResAndUCResUnboundedLoop()
        internal
        returns (uint256 totalECRes_, uint256 totalUCRes_)
    {
        for (uint256 i = 1; i <= memberIdCounter; ) {
            Member storage memberToCheck = idToMember[i];
            if (memberToCheck.memberState == MemberState.Active) {
                (uint256 memberEcr, uint256 memberUcr) = ReserveMathLib._calculateEcrAndUcrByMember(
                    memberToCheck
                );

                totalECRes_ += memberEcr;
                totalUCRes_ += memberUcr;
            }

            unchecked {
                ++i;
            }
        }
    }

    function _calculateSurplus() internal returns (uint256 surplus_) {
        int256 possibleSurplus;

        (uint256 totalECRes, uint256 totalUCRes) = _totalECResAndUCResUnboundedLoop();
        uint256 UCRisk;

        if (totalUCRes * reserve.riskMultiplier > 0) {
            UCRisk = totalUCRes * reserve.riskMultiplier;
        }

        // surplus = max(0, ECRes - max(0, UCRisk - UCRes -  RPOOL))

        int256 unearned = int256(UCRisk) - int256(totalUCRes) - int256(RPOOL);

        if (unearned < 0) {
            unearned = 0;
        }

        possibleSurplus = int256(totalECRes) - unearned;

        if (possibleSurplus < 0) {
            surplus_ = 0;
        } else {
            surplus_ = uint256(possibleSurplus);
        }

        reserve.surplus = surplus_;

        emit TakasureEvents.OnFundSurplusUpdated(surplus_);
    }

    function _memberSurplus() internal {
        uint256 totalSurplus = _calculateSurplus();
        uint256 userCreditTokensBalance = reserve.members[msg.sender].creditTokensBalance;
        uint256 totalCreditTokens = daoToken.balanceOf(address(this));
        uint256 userSurplus = (totalSurplus * userCreditTokensBalance) / totalCreditTokens;
        reserve.members[msg.sender].memberSurplus = userSurplus;
        emit TakasureEvents.OnMemberSurplusUpdated(
            reserve.members[msg.sender].memberId,
            userSurplus
        );
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DAO_MULTISIG) {}
}
