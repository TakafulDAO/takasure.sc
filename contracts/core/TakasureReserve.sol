//SPDX-License-Identifier: GPL-3.0

/**
 * @title TakasureReserve
 * @author Maikel Ordaz
 * @notice This contract will hold all the reserve values and the members data as well as balances
 * @dev Modules will be able to interact with this contract to update the reserve values and the members data
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IModuleManager} from "contracts/interfaces/IModuleManager.sol";
import {IAddressManager} from "contracts/interfaces/IAddressManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {TSToken} from "contracts/token/TSToken.sol";

import {Reserve, Member, MemberState, CashFlowVars, TakasureReserveInitParams} from "contracts/types/TakasureTypes.sol";
import {ReserveMathAlgorithms} from "contracts/helpers/libraries/algorithms/ReserveMathAlgorithms.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";

pragma solidity 0.8.28;

contract TakasureReserve is Initializable, UUPSUpgradeable, PausableUpgradeable {
    IModuleManager public moduleManager;
    IAddressManager public addressManager;

    Reserve private reserve;
    CashFlowVars private cashFlowVars;

    address public bmConsumer;
    address public kycProvider;
    address public feeClaimAddress;
    address public takadaoOperator;
    address public daoMultisig;
    address private pauseGuardian;

    uint256 private RPOOL;

    bytes32 internal constant OPERATOR = keccak256("OPERATOR");
    bytes32 internal constant DAO_MULTISIG = keccak256("DAO_MULTISIG");
    bytes32 private constant PAUSE_GUARDIAN = keccak256("PAUSE_GUARDIAN");

    mapping(uint16 month => uint256 monthCashFlow) public monthToCashFlow;
    mapping(uint16 month => mapping(uint8 day => uint256 dayCashFlow)) public dayToCashFlow;

    mapping(address member => Member) private members;
    mapping(uint256 memberIdCounter => address memberWallet) private idToMemberWallet;

    error TakasureReserve__OnlyDaoOrTakadao();
    error TakasureReserve__WrongValue();
    error TakasureReserve__UnallowedAccess();

    modifier onlyRole(bytes32 role) {
        require(addressManager.hasRole(role, msg.sender), TakasureReserve__UnallowedAccess());
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(TakasureReserveInitParams memory _initParams) external initializer {
        __UUPSUpgradeable_init();
        // __AccessControl_init();
        __Pausable_init();
        // _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        // _grantRole(OPERATOR, _initParams.takadaoOperator);
        // _grantRole(DAO_MULTISIG, _initParams.daoOperator);
        // _grantRole(PAUSE_GUARDIAN, _initParams.pauseGuardian);

        moduleManager = IModuleManager(_initParams.moduleManager);
        addressManager = IAddressManager(_initParams.addressManager);
        takadaoOperator = _initParams.takadaoOperator;
        daoMultisig = _initParams.daoOperator;
        kycProvider = _initParams.kycProvider;
        feeClaimAddress = _initParams.feeClaimAddress;
        pauseGuardian = _initParams.pauseGuardian;

        TSToken daoToken = new TSToken(
            _initParams.tokenAdmin,
            msg.sender,
            _initParams.moduleManager,
            _initParams.tokenName,
            _initParams.tokenSymbol
        );

        cashFlowVars.monthReference = 1;
        cashFlowVars.dayReference = 1;

        reserve.referralDiscount = true; // Default
        reserve.serviceFee = 27; // 27% of the contribution amount. Default
        reserve.lossRatioThreshold = 80; // 80% Default
        reserve.bmaFundReserveShare = 70; // 70% Default
        reserve.fundMarketExpendsAddShare = 20; // 20% Default
        reserve.riskMultiplier = 2; // 2% Default
        reserve.isOptimizerEnabled = true; // Default
        reserve.daoToken = address(daoToken);
        reserve.contributionToken = _initParams.contributionToken;
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

    function setMemberValuesFromModule(Member memory newMember) external whenNotPaused {
        _onlyModule();
        members[newMember.wallet] = newMember;
        idToMemberWallet[newMember.memberId] = newMember.wallet;
    }

    function setReserveValuesFromModule(Reserve memory newReserve) external whenNotPaused {
        _onlyModule();
        reserve = newReserve;
    }

    function setCashFlowValuesFromModule(
        CashFlowVars memory newCashFlowVars
    ) external whenNotPaused {
        _onlyModule();
        cashFlowVars = newCashFlowVars;
    }

    function setMonthToCashFlowValuesFromModule(
        uint16 month,
        uint256 monthCashFlow
    ) external whenNotPaused {
        _onlyModule();
        monthToCashFlow[month] = monthCashFlow;
    }

    function setDayToCashFlowValuesFromModule(
        uint16 month,
        uint8 day,
        uint256 dayCashFlow
    ) external whenNotPaused {
        _onlyModule();
        dayToCashFlow[month][day] = dayCashFlow;
    }

    function setModuleManagerContract(address newModuleManagerContract) external {
        _onlyDaoOrTakadao();
        AddressAndStates._notZeroAddress(newModuleManagerContract);
        moduleManager = IModuleManager(newModuleManagerContract);
    }

    function setNewServiceFee(uint8 newServiceFee) external onlyRole(OPERATOR) {
        require(newServiceFee <= 35, TakasureReserve__WrongValue());
        reserve.serviceFee = newServiceFee;

        emit TakasureEvents.OnServiceFeeChanged(newServiceFee);
    }

    function setNewFundMarketExpendsShare(
        uint8 newFundMarketExpendsAddShare
    ) external onlyRole(DAO_MULTISIG) {
        require(newFundMarketExpendsAddShare <= 35, TakasureReserve__WrongValue());

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

    function setRiskMultiplier(uint8 newRiskMultiplier) external onlyRole(DAO_MULTISIG) {
        require(newRiskMultiplier <= 100, TakasureReserve__WrongValue());
        reserve.riskMultiplier = newRiskMultiplier;

        emit TakasureEvents.OnNewRiskMultiplier(newRiskMultiplier);
    }

    function setNewFeeClaimAddress(address newFeeClaimAddress) external onlyRole(OPERATOR) {
        AddressAndStates._notZeroAddress(newFeeClaimAddress);
        feeClaimAddress = newFeeClaimAddress;
    }

    function setReferralDiscountState(bool referralDiscountState) external onlyRole(OPERATOR) {
        reserve.referralDiscount = referralDiscountState;
    }

    function setNewBenefitMultiplierConsumerAddress(
        address newBenefitMultiplierConsumerAddress
    ) external {
        _onlyDaoOrTakadao();
        AddressAndStates._notZeroAddress(newBenefitMultiplierConsumerAddress);
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

    // todo: ser operator address in address manager
    // function setNewOperatorAddress(address newOperatorAddress) external {
    //     _onlyDaoOrTakadao();
    //     address oldOperator = takadaoOperator;
    //     takadaoOperator = newOperatorAddress;

    //     _grantRole(OPERATOR, newOperatorAddress);
    //     _revokeRole(OPERATOR, oldOperator);

    //     emit TakasureEvents.OnOperatorChanged(newOperatorAddress, oldOperator);
    // }

    // todo: set pause guardian in address manager
    // function setNewPauseGuardianAddress(address newPauseGuardianAddress) external {
    //     _onlyDaoOrTakadao();
    //     address oldPauseGuardian = pauseGuardian;
    //     pauseGuardian = newPauseGuardianAddress;

    //     _grantRole(PAUSE_GUARDIAN, newPauseGuardianAddress);
    //     _revokeRole(PAUSE_GUARDIAN, oldPauseGuardian);
    // }

    /**
     * @notice Calculate the surplus for a member
     */
    function memberSurplus(Member memory newMemberValues) external {
        _onlyModule();
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
                (monthsPassed * 30 days);
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

    function _cashLast12Months(
        uint16 _currentMonth,
        uint8 _currentDay
    ) internal view returns (uint256 cashLast12Months_) {
        uint256 cash = 0;

        // Then make the iterations, according the month and day this function is called
        if (_currentMonth < 13) {
            // If less than a complete year, iterate through every month passed
            // Return everything stored in the mappings until now
            for (uint8 i = 1; i <= _currentMonth; ++i) {
                cash += monthToCashFlow[i];
            }
        } else {
            // If more than a complete year, iterate the last 11 completed months
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
    function _totalECResAndUCResUnboundedLoop()
        internal
        returns (uint256 totalECRes_, uint256 totalUCRes_)
    {
        Reserve memory currentReserve = reserve;
        // We check for every member except the recently added
        for (uint256 i = 1; i <= currentReserve.memberIdCounter - 1; ++i) {
            address memberWallet = idToMemberWallet[i];
            Member storage memberToCheck = members[memberWallet];
            if (memberToCheck.memberState == MemberState.Active) {
                (uint256 memberEcr, uint256 memberUcr) = ReserveMathAlgorithms
                    ._calculateEcrAndUcrByMember(memberToCheck);

                totalECRes_ += memberEcr;
                totalUCRes_ += memberUcr;
            }
        }

        reserve.ECRes = totalECRes_;
        reserve.UCRes = totalUCRes_;
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
            ReserveMathAlgorithms._maxInt(
                0,
                (int256(totalECRes) -
                    ReserveMathAlgorithms._maxInt(
                        0,
                        (int256(UCRisk) - int256(totalUCRes) - int256(RPOOL))
                    ))
            )
        );

        reserve.surplus = surplus_;

        emit TakasureEvents.OnFundSurplusUpdated(surplus_);
    }

    function _onlyModule() internal view {
        require(moduleManager.isActiveModule(msg.sender), TakasureReserve__UnallowedAccess());
    }

    function _onlyDaoOrTakadao() internal view {
        require(
            addressManager.hasRole(OPERATOR, msg.sender) ||
                addressManager.hasRole(DAO_MULTISIG, msg.sender),
            TakasureReserve__OnlyDaoOrTakadao()
        );
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DAO_MULTISIG) {}
}
