//SPDX-License-Identifier: GPL-3.0

/**
 * @title TakasureReserve
 * @author Maikel Ordaz
 * @notice This contract will hold all the reserve values and the members data as well as balances
 * @dev Modules will be able to interact with this contract to update the reserve values and the members data
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {TSToken} from "contracts/token/TSToken.sol";

import {Reserve, Member, MemberState, CashFlowVars} from "contracts/types/TakasureTypes.sol";
import {ReserveMathLib} from "contracts/libraries/ReserveMathLib.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {GlobalErrors} from "contracts/libraries/GlobalErrors.sol";

pragma solidity 0.8.28;

contract TakasureReserve is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    Reserve private reserve;
    CashFlowVars private cashFlowVars;

    address public bmConsumer;
    address public kycProvider;
    address public feeClaimAddress;
    address public takadaoOperator;
    address public daoMultisig;
    address private pauseGuardian;
    address private joinModuleContract;
    address private memberModuleContract;
    address private claimModuleContract;

    uint256 private RPOOL; // todo: define this value

    bytes32 internal constant TAKADAO_OPERATOR = keccak256("TAKADAO_OPERATOR");
    bytes32 internal constant DAO_MULTISIG = keccak256("DAO_MULTISIG");
    bytes32 private constant PAUSE_GUARDIAN = keccak256("PAUSE_GUARDIAN");
    bytes32 private constant MODULE_CONTRACT = keccak256("MODULE_CONTRACT");

    mapping(uint16 month => uint256 montCashFlow) public monthToCashFlow;
    mapping(uint16 month => mapping(uint8 day => uint256 dayCashFlow)) public dayToCashFlow; // ? Maybe better block.timestamp => dailyDeposits for this one?

    mapping(address member => Member) private members;
    mapping(uint256 memberIdCounter => address memberWallet) private idToMemberWallet;

    error TakasureReserve__OnlyDaoOrTakadao();
    error TakasureReserve__WrongServiceFee();
    error TakasureReserve__WrongFundMarketExpendsShare();

    modifier notZeroAddress(address _address) {
        require(_address != address(0), GlobalErrors.TakasureProtocol__ZeroAddress());
        _;
    }

    modifier onlyDaoOrTakadao() {
        require(
            hasRole(TAKADAO_OPERATOR, msg.sender) ||
                hasRole(DAO_MULTISIG, msg.sender) ||
                hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            TakasureReserve__OnlyDaoOrTakadao()
        );
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
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(TAKADAO_OPERATOR, _takadaoOperator);
        _grantRole(DAO_MULTISIG, _daoOperator);
        _grantRole(PAUSE_GUARDIAN, _pauseGuardian);

        takadaoOperator = _takadaoOperator;
        daoMultisig = _daoOperator;
        kycProvider = _kycProvider;
        feeClaimAddress = _feeClaimAddress;
        pauseGuardian = _pauseGuardian;

        TSToken daoToken = new TSToken(_tokenAdmin, msg.sender, _tokenName, _tokenSymbol);

        cashFlowVars.monthReference = 1;
        cashFlowVars.dayReference = 1;

        reserve.serviceFee = 22; // 22% of the contribution amount. Default
        reserve.bmaFundReserveShare = 70; // 70% Default
        reserve.fundMarketExpendsAddShare = 20; // 20% Default
        reserve.riskMultiplier = 2; // 2% Default
        reserve.isOptimizerEnabled = true; // Default
        reserve.daoToken = address(daoToken);
        reserve.contributionToken = _contributionToken;
        reserve.minimumThreshold = 25e6; // 25 USDC // 6 decimals
        reserve.maximumThreshold = 250e6; // 250 USDC // 6 decimals
        reserve.initialReserveRatio = 40; // 40% Default
        reserve.dynamicReserveRatio = 40; // Default
        reserve.benefitMultiplierAdjuster = 100; // 100% Default

        emit TakasureEvents.OnInitialReserveValues(
            reserve.initialReserveRatio,
            reserve.dynamicReserveRatio,
            reserve.benefitMultiplierAdjuster,
            reserve.serviceFee,
            reserve.bmaFundReserveShare,
            reserve.isOptimizerEnabled,
            reserve.contributionToken,
            reserve.daoToken
        );
    }

    function pause() external onlyRole(PAUSE_GUARDIAN) {
        _pause();
    }

    function unpause() external onlyRole(PAUSE_GUARDIAN) {
        _unpause();
    }

    function setMemberValuesFromModule(
        Member memory newMember
    ) external whenNotPaused onlyRole(MODULE_CONTRACT) {
        members[newMember.wallet] = newMember;
        idToMemberWallet[newMember.memberId] = newMember.wallet;
    }

    function setReserveValuesFromModule(
        Reserve memory newReserve
    ) external whenNotPaused onlyRole(MODULE_CONTRACT) {
        reserve = newReserve;
    }

    function setCashFlowValuesFromModule(
        CashFlowVars memory newCashFlowVars
    ) external whenNotPaused onlyRole(MODULE_CONTRACT) {
        cashFlowVars = newCashFlowVars;
    }

    function setMonthToCashFlowValuesFromModule(
        uint16 month,
        uint256 monthCashFlow
    ) external whenNotPaused onlyRole(MODULE_CONTRACT) {
        monthToCashFlow[month] = monthCashFlow;
    }

    function setDayToCashFlowValuesFromModule(
        uint16 month,
        uint8 day,
        uint256 dayCashFlow
    ) external whenNotPaused onlyRole(MODULE_CONTRACT) {
        dayToCashFlow[month][day] = dayCashFlow;
    }

    function setNewModuleContract(
        address newModuleContract
    ) external onlyDaoOrTakadao notZeroAddress(newModuleContract) {
        grantRole(MODULE_CONTRACT, newModuleContract);
    }

    function setNewServiceFee(uint8 newServiceFee) external onlyRole(TAKADAO_OPERATOR) {
        require(newServiceFee <= 35, TakasureReserve__WrongServiceFee());
        reserve.serviceFee = newServiceFee;

        emit TakasureEvents.OnServiceFeeChanged(newServiceFee);
    }

    function setNewFundMarketExpendsShare(
        uint8 newFundMarketExpendsAddShare
    ) external onlyRole(DAO_MULTISIG) {
        require(newFundMarketExpendsAddShare <= 35, TakasureReserve__WrongFundMarketExpendsShare());

        uint8 oldFundMarketExpendsAddShare = reserve.fundMarketExpendsAddShare;
        reserve.fundMarketExpendsAddShare = newFundMarketExpendsAddShare;

        emit TakasureEvents.OnNewMarketExpendsFundReserveAddShare(
            newFundMarketExpendsAddShare,
            oldFundMarketExpendsAddShare
        );
    }

    function setAllowCustomDuration(bool _allowCustomDuration) external onlyRole(DAO_MULTISIG) {
        reserve.allowCustomDuration = _allowCustomDuration;

        emit TakasureEvents.OnAllowCustomDuration(_allowCustomDuration);
    }

    function setNewMinimumThreshold(uint256 newMinimumThreshold) external onlyRole(DAO_MULTISIG) {
        reserve.minimumThreshold = newMinimumThreshold;

        emit TakasureEvents.OnNewMinimumThreshold(newMinimumThreshold);
    }

    function setNewMaximumThreshold(uint256 newMaximumThreshold) external onlyRole(DAO_MULTISIG) {
        reserve.maximumThreshold = newMaximumThreshold;

        emit TakasureEvents.OnNewMaximumThreshold(newMaximumThreshold);
    }

    function setNewContributionToken(
        address newContributionToken
    ) external onlyRole(DAO_MULTISIG) notZeroAddress(newContributionToken) {
        reserve.contributionToken = newContributionToken;
    }

    function setNewFeeClaimAddress(
        address newFeeClaimAddress
    ) external onlyRole(TAKADAO_OPERATOR) notZeroAddress(newFeeClaimAddress) {
        feeClaimAddress = newFeeClaimAddress;
    }

    function setNewBenefitMultiplierConsumerAddress(
        address newBenefitMultiplierConsumerAddress
    ) external onlyDaoOrTakadao notZeroAddress(newBenefitMultiplierConsumerAddress) {
        address oldBenefitMultiplierConsumer = address(bmConsumer);
        bmConsumer = newBenefitMultiplierConsumerAddress;

        emit TakasureEvents.OnBenefitMultiplierConsumerChanged(
            newBenefitMultiplierConsumerAddress,
            oldBenefitMultiplierConsumer
        );
    }

    function setNewKycProviderAddress(
        address newKycProviderAddress
    ) external onlyRole(DAO_MULTISIG) {
        kycProvider = newKycProviderAddress;
    }

    function setNewPauseGuardianAddress(address newPauseGuardianAddress) external onlyDaoOrTakadao {
        address oldPauseGuardian = pauseGuardian;
        pauseGuardian = newPauseGuardianAddress;

        _grantRole(PAUSE_GUARDIAN, newPauseGuardianAddress);
        _revokeRole(PAUSE_GUARDIAN, oldPauseGuardian);
    }

    function getReserveValues() external view returns (Reserve memory) {
        return reserve;
    }

    function getMemberFromAddress(address member) external view returns (Member memory) {
        return members[member];
    }

    function getMemberFromId(uint256 memberId) external view returns (address) {
        return idToMemberWallet[memberId];
    }

    function getCashFlowValues() external view returns (CashFlowVars memory) {
        return cashFlowVars;
    }

    /**
     * @notice Get the cash flow for the last 12 months. From the time is called
     * @return cash_ the cash flow for the last 12 months
     */
    function getCashLast12Months() external view returns (uint256 cash_) {
        (uint16 monthFromCall, uint8 dayFromCall) = _monthAndDayFromCall();
        cash_ = _cashLast12Months(monthFromCall, dayFromCall);
    }

    function _monthAndDayFromCall()
        internal
        view
        returns (uint16 currentMonth_, uint8 currentDay_)
    {
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
                (monthsPassed * 30 days);
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

    function _cashLast12Months(
        uint16 _currentMonth,
        uint8 _currentDay
    ) internal view returns (uint256 cashLast12Months_) {
        uint256 cash = 0;

        // Then make the iterations, according the month and day this function is called
        if (_currentMonth < 13) {
            // Less than a complete year, iterate through every month passed
            // Return everything stored in the mappings until now
            for (uint8 i = 1; i <= _currentMonth; ++i) {
                cash += monthToCashFlow[i];
            }
        } else {
            // More than a complete year has passed, iterate the last 11 completed months
            // This happens since month 13
            uint16 monthBackCounter;
            uint16 monthsInYear = 12;

            for (uint8 i; i < monthsInYear; ++i) {
                monthBackCounter = _currentMonth - i;
                cash += monthToCashFlow[monthBackCounter];
            }

            // Iterate an extra month to complete the days that are left from the current month
            uint16 extraMonthToCheck = _currentMonth - monthsInYear;
            uint8 dayBackCounter = 30;
            uint8 extraDaysToCheck = dayBackCounter - _currentDay;

            for (uint8 i; i < extraDaysToCheck; ++i) {
                cash += dayToCashFlow[extraMonthToCheck][dayBackCounter];

                unchecked {
                    --dayBackCounter;
                }
            }
        }

        cashLast12Months_ = cash;
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
        Reserve memory currentReserve = reserve;
        uint256 newECRes;
        // We check for every member except the recently added
        for (uint256 i = 1; i <= currentReserve.memberIdCounter - 1; ++i) {
            address memberWallet = idToMemberWallet[i];
            Member storage memberToCheck = members[memberWallet];
            if (memberToCheck.memberState == MemberState.Active) {
                (uint256 memberEcr, uint256 memberUcr) = ReserveMathLib._calculateEcrAndUcrByMember(
                    memberToCheck
                );

                newECRes += memberEcr;
                totalUCRes_ += memberUcr;
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

        UCRisk = (totalUCRes * reserve.riskMultiplier) / 100;

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
    function memberSurplus(Member memory newMemberValues) external onlyRole(MODULE_CONTRACT) {
        uint256 totalSurplus = _calculateSurplus();
        uint256 userCreditTokensBalance = newMemberValues.creditTokensBalance;
        address daoToken = reserve.daoToken;
        uint256 totalCreditTokens = IERC20(daoToken).balanceOf(address(this)) +
            userCreditTokensBalance;
        uint256 userSurplus = (totalSurplus * userCreditTokensBalance) / totalCreditTokens;
        members[newMemberValues.wallet].memberSurplus = userSurplus;
        emit TakasureEvents.OnMemberSurplusUpdated(
            members[newMemberValues.wallet].memberId,
            userSurplus
        );
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DAO_MULTISIG) {}
}
