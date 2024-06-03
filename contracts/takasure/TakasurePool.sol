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
import {ITLDToken} from "../interfaces/ITLDToken.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Fund, Member, MemberState, KYC} from "../types/TakasureTypes.sol";
import {ReserveMathLib} from "../libraries/ReserveMathLib.sol";

pragma solidity 0.8.25;

contract TakasurePool is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    IERC20 private contributionToken;
    ITLDToken private tldToken;

    Fund private pool;

    uint256 private constant DECIMALS_PRECISION = 1e12;
    uint256 private constant DECIMAL_REQUIREMENT_PRECISION_USDC = 1e4; // 4 decimals to receive at minimum 0.01 USDC
    uint256 private constant DEFAULT_MEMBERSHIP_DURATION = 5 * (365 days); // 5 year
    uint256 private constant MONTH = 30 days; // Todo: manage a better way for 365 days and leap years maybe?
    uint256 private constant DAY = 1 days;

    bool public allowCustomDuration; // while false, the membership duration is fixed to 5 years

    uint256 private dayDepositTimestamp; // 0 at begining, then never is zero again
    uint256 private monthDepositTimestamp; // 0 at begining, then never is zero again
    uint16 private monthReference; // Will count the month. For gas issues will grow undefinitely
    uint8 private dayReference; // Will count the day of the month from 1 -> 30, then resets to 1

    uint256 public minimumThreshold;
    uint256 public memberIdCounter;
    address public wakalaClaimAddress;

    mapping(uint256 memberIdCounter => Member) private idToMember;
    mapping(address memberAddress => KYC) private memberKYC; // Todo: Implement KYC correctly in the future

    mapping(uint16 month => uint256 montCashFlow) private monthToCashFlow;
    mapping(uint16 month => mapping(uint8 day => uint256 dayCashFlow)) private dayToCashFlow; // ? Maybe better block.timestamp => dailyDeposits for this one?

    event MemberJoined(address indexed member, uint256 indexed contributionAmount, KYC indexed kyc);

    error TakasurePool__MemberAlreadyExists();
    error TakasurePool__ZeroAddress();
    error TakasurePool__ContributionBelowMinimumThreshold();
    error TakasurePool__ContributionTransferFailed();
    error TakasurePool__FeeTransferFailed();
    error TakasurePool__MintFailed();
    error TakasurePool__WrongWakalaFee();

    modifier notZeroAddress(address _address) {
        if (_address == address(0)) {
            revert TakasurePool__ZeroAddress();
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param _contributionToken default USDC
     * @param _tldToken utility token for the DAO
     * @param _wakalaClaimAddress address allowed to claim the wakala fee
     * @param _daoOperator address allowed to manage the DAO
     * @dev it reverts if any of the addresses is zero
     */
    function initialize(
        address _contributionToken,
        address _tldToken,
        address _wakalaClaimAddress,
        address _daoOperator
    )
        external
        initializer
        notZeroAddress(_contributionToken)
        notZeroAddress(_tldToken)
        notZeroAddress(_wakalaClaimAddress)
        notZeroAddress(_daoOperator)
    {
        __UUPSUpgradeable_init();
        __Ownable_init(_daoOperator);

        contributionToken = IERC20(_contributionToken);
        tldToken = ITLDToken(_tldToken);
        wakalaClaimAddress = _wakalaClaimAddress;

        monthReference = 1;
        dayReference = 1;
        minimumThreshold = 25e6; // 25 USDC // 6 decimals

        pool.dynamicReserveRatio = 40; // 40% Default
        pool.benefitMultiplierAdjuster = 1; // Default
        pool.totalContributions = 0;
        pool.totalClaimReserve = 0;
        pool.totalFundReserve = 0;
        pool.wakalaFee = 20; // 20% of the contribution amount. Default
    }

    /**
     * @notice Allow new members to join the pool
     * @param benefitMultiplier fetched from off-chain oracle
     * @param contributionAmount in six decimals
     * @param membershipDuration default 5 years
     * @dev it reverts if the contribution is less than the minimum threshold defaultes to `minimumThreshold`
     * @dev it reverts if the member is already active
     * @dev the contribution amount will be round down so the last four decimals will be zero. This means
     *      that the minimum contribution amount is 0.01 USDC
     */
    function joinPool(
        uint256 benefitMultiplier,
        uint256 contributionAmount,
        uint256 membershipDuration
    ) external {
        // Todo: Check the user benefit multiplier against the oracle.
        if (pool.members[msg.sender].memberState == MemberState.Active) {
            revert TakasurePool__MemberAlreadyExists();
        }
        if (contributionAmount < minimumThreshold) {
            revert TakasurePool__ContributionBelowMinimumThreshold();
        }

        // Todo: re-calculate BMA, and DAO Surplus.

        // Create new member
        memberIdCounter++;

        // The minimum we can receive is 0,01 USDC, here we round it. This to prevent rounding errors
        // i.e. contributionAmount = (25.123456 / 1e4) * 1e4 = 25.12USDC
        contributionAmount =
            (contributionAmount / DECIMAL_REQUIREMENT_PRECISION_USDC) *
            DECIMAL_REQUIREMENT_PRECISION_USDC;

        uint256 userMembershipDuration;

        if (allowCustomDuration) {
            userMembershipDuration = membershipDuration;
        } else {
            userMembershipDuration = DEFAULT_MEMBERSHIP_DURATION;
        }

        Member memory newMember = Member({
            memberId: memberIdCounter,
            benefitMultiplier: benefitMultiplier,
            membershipDuration: userMembershipDuration,
            membershipStartTime: block.timestamp,
            netContribution: contributionAmount,
            wallet: msg.sender,
            memberState: MemberState.Active,
            surplus: 0 // Todo
        });

        uint256 mintAmount = contributionAmount * DECIMALS_PRECISION; // 6 decimals to 18 decimals
        uint256 wakalaAmount = (contributionAmount * pool.wakalaFee) / 100;
        uint256 depositAmount = contributionAmount - wakalaAmount;

        // Distribute between the claim and fund reserve
        uint256 toFundReserve = (depositAmount * pool.dynamicReserveRatio) / 100;
        uint256 toClaimReserve = depositAmount - toFundReserve;

        uint256 updatedProFormaFundReserve = ReserveMathLib._updateProFormaFundReserve(
            pool.proFormaFundReserve,
            newMember.netContribution,
            pool.dynamicReserveRatio
        );

        // Update the fund reserve to use it in the dynamic reserve ratio calculation
        pool.totalFundReserve += toFundReserve;

        _updateCashMappings(depositAmount);
        uint256 cashLast12Months = _cashLast12Months(monthReference, dayReference);

        uint256 updatedDynamicReserveRatio = ReserveMathLib
            ._calculateDynamicReserveRatioReserveShortfallMethod(
                pool.dynamicReserveRatio,
                updatedProFormaFundReserve,
                pool.totalFundReserve,
                cashLast12Months
            );

        // Update all the other values in the pool
        pool.members[msg.sender] = newMember;
        pool.proFormaFundReserve = updatedProFormaFundReserve;
        pool.dynamicReserveRatio = updatedDynamicReserveRatio;
        pool.totalContributions += contributionAmount;
        pool.totalClaimReserve += toClaimReserve;

        // Add the member to the mapping
        idToMember[memberIdCounter] = newMember;

        // External calls
        bool success;

        // Mint The Life DAO Token
        success = tldToken.mint(msg.sender, mintAmount);
        if (!success) {
            revert TakasurePool__MintFailed();
        }

        // Transfer the contribution to the pool
        success = contributionToken.transferFrom(msg.sender, address(this), depositAmount);
        if (!success) {
            revert TakasurePool__ContributionTransferFailed();
        }

        // Transfer the wakala fee to the DAO
        success = contributionToken.transferFrom(msg.sender, wakalaClaimAddress, wakalaAmount);
        if (!success) {
            revert TakasurePool__FeeTransferFailed();
        }

        emit MemberJoined(msg.sender, contributionAmount, memberKYC[msg.sender]);
    }

    function setNewWakalaFee(uint8 newWakalaFee) external onlyOwner {
        if (newWakalaFee > 100) {
            revert TakasurePool__WrongWakalaFee();
        }
        pool.wakalaFee = newWakalaFee;
    }

    function setNewMinimumThreshold(uint256 newMinimumThreshold) external onlyOwner {
        minimumThreshold = newMinimumThreshold;
    }

    function setNewContributionToken(
        address newContributionToken
    ) external onlyOwner notZeroAddress(newContributionToken) {
        contributionToken = IERC20(newContributionToken);
    }

    function setNewWakalaClaimAddress(
        address newWakalaClaimAddress
    ) external onlyOwner notZeroAddress(newWakalaClaimAddress) {
        wakalaClaimAddress = newWakalaClaimAddress;
    }

    function setAllowCustomDuration(bool _allowCustomDuration) external onlyOwner {
        allowCustomDuration = _allowCustomDuration;
    }

    function getPoolValues()
        external
        view
        returns (
            uint256 proFormaFundReserve_,
            uint256 dynamicReserveRatio_,
            uint256 benefitMultiplierAdjuster_,
            uint256 totalContributions_,
            uint256 totalClaimReserve_,
            uint256 totalFundReserve_,
            uint8 wakalaFee_
        )
    {
        proFormaFundReserve_ = pool.proFormaFundReserve;
        dynamicReserveRatio_ = pool.dynamicReserveRatio;
        benefitMultiplierAdjuster_ = pool.benefitMultiplierAdjuster;
        totalContributions_ = pool.totalContributions;
        totalClaimReserve_ = pool.totalClaimReserve;
        totalFundReserve_ = pool.totalFundReserve;
        wakalaFee_ = pool.wakalaFee;
    }

    function getMemberKYC(address member) external view returns (KYC) {
        return memberKYC[member];
    }

    function getMemberFromId(uint256 memberId) external view returns (Member memory) {
        return idToMember[memberId];
    }

    function getMemberFromAddress(address member) external view returns (Member memory) {
        return pool.members[member];
    }

    function getTldTokenAddress() external view returns (address) {
        return address(tldToken);
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

    function _updateCashMappings(uint256 _depositAmount) internal {
        uint256 currentTimestamp = block.timestamp;

        if (dayDepositTimestamp == 0 && monthDepositTimestamp == 0) {
            // If the depositTimestamp is 0 it means it is the first deposit
            // Set the initial values for future calculations and reference
            dayDepositTimestamp = currentTimestamp;
            monthDepositTimestamp = currentTimestamp;
            monthToCashFlow[monthReference] = _depositAmount;
            dayToCashFlow[monthReference][dayReference] = _depositAmount;
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
                monthToCashFlow[monthReference] += _depositAmount;
                if (daysPassed == 0) {
                    // If no days have passed, update the mapping for the current day
                    dayToCashFlow[monthReference][dayReference] += _depositAmount;
                } else {
                    // If it is a new day, update the day deposit timestamp and the new day reference
                    dayDepositTimestamp += daysPassed * DAY;
                    dayReference += uint8(daysPassed);

                    // Update the mapping for the new day
                    dayToCashFlow[monthReference][dayReference] = _depositAmount;
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
                monthToCashFlow[monthReference] = _depositAmount;
                dayToCashFlow[monthReference][dayReference] = _depositAmount;
            }
        }
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

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
