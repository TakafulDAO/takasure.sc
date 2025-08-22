// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title ReferralGateway
 * @author Maikel Ordaz
 * @dev This contract will manage all the functionalities related to the referral system and pre-joins
 *      to the LifeDAO protocol
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISubscriptionModule} from "contracts/interfaces/ISubscriptionModule.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

pragma solidity 0.8.28;

/// @custom:oz-upgrades-from contracts/version_previous_contracts/ReferralGatewayV1.sol:ReferralGatewayV1
contract ReferralGateway is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    IERC20 public usdc;
    address private bmConsumer; // DEPRECATED!!!

    address private operator;

    mapping(string tDAOName => tDAO DAOData) private nameToDAOData;
    mapping(address member => bool) public isMemberKYCed;
    mapping(address child => address parent) public childToParent;

    address private couponPool;
    address private ccipReceiverContract; // DEPRECATED!!!

    struct PrepaidMember {
        address member;
        uint256 contributionBeforeFee;
        uint256 contributionAfterFee;
        uint256 feeToOperator; // Fee after all the discounts and rewards
        uint256 discount;
        mapping(address child => uint256 rewards) parentRewardsByChild;
        mapping(uint256 layer => uint256 rewards) parentRewardsByLayer;
        bool isDonated;
    }

    struct tDAO {
        mapping(address member => PrepaidMember) prepaidMembers;
        string name;
        bool preJoinDiscountEnabled;
        bool referralDiscountEnabled;
        address DAOAdmin; // The one that can modify the DAO settings
        address DAOAddress; // To be assigned when the tDAO is deployed
        uint256 launchDate; // In seconds. An estimated launch date of the DAO
        uint256 objectiveAmount; // In USDC, six decimals
        uint256 currentAmount; // In USDC, six decimals
        uint256 collectedFees; // Fees collected after deduct, discounts, referral reserve and repool amounts. In USDC, six decimals
        address rePoolAddress; // To be assigned when the tDAO is deployed
        uint256 toRepool; // In USDC, six decimals
        uint256 referralReserve; // In USDC, six decimals
        address bmConsumer; // DEPRECATED!!!
        address subscriptionModule;
        bool rewardsEnabled;
    }

    // Set to true when new members use coupons to pay their contributions. It does not matter the amount
    mapping(address member => bool) private isMemberCouponRedeemer;

    string public daoName;

    /*//////////////////////////////////////////////////////////////
                              FIXED RATIOS
    //////////////////////////////////////////////////////////////*/

    uint8 private constant SERVICE_FEE_RATIO = 27;
    uint256 private constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee
    uint256 private constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution deducted from contribution
    uint256 private constant REFERRAL_RESERVE = 5; // 5% of contribution TO Referral Reserve
    uint256 private constant REPOOL_FEE_RATIO = 2; // 2% of contribution deducted from fee
    uint256 private constant MINIMUM_CONTRIBUTION = 25e6; // 25 USDC
    uint256 private constant MAXIMUM_CONTRIBUTION = 250e6; // 250 USDC
    uint256 private constant DECIMAL_REQUIREMENT_PRECISION_USDC = 1e4; // 4 decimals to receive at minimum 0.01 USDC

    /*//////////////////////////////////////////////////////////////
                            REWARDS RELATED
    //////////////////////////////////////////////////////////////*/

    int256 private constant MAX_TIER = 4;
    int256 private constant A = -3_125;
    int256 private constant B = 30_500;
    int256 private constant C = -99_625;
    int256 private constant D = 112_250;
    uint256 private constant DECIMAL_CORRECTION = 10_000;

    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/

    bytes32 private constant OPERATOR = keccak256("OPERATOR");
    bytes32 private constant KYC_PROVIDER = keccak256("KYC_PROVIDER");
    bytes32 private constant PAUSE_GUARDIAN = keccak256("PAUSE_GUARDIAN");
    bytes32 private constant COUPON_REDEEMER = keccak256("COUPON_REDEEMER");

    /*//////////////////////////////////////////////////////////////
                            EVENTS & ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnNewDAO(
        bool indexed preJoinDiscountEnabled,
        bool indexed referralDiscount,
        uint256 launchDate,
        uint256 objectiveAmount
    );
    event OnDAOLaunchDateUpdated(uint256 indexed launchDate);
    event OnDAOLaunched(address indexed DAOAddress);
    event OnReferralDiscountSwitched(bool indexed referralDiscount);
    event OnRepoolEnabled(address indexed rePoolAddress);
    event OnPrepayment(
        address indexed parent,
        address indexed child,
        uint256 indexed contribution,
        uint256 fee,
        uint256 discount
    );
    event OnCouponRedeemed(
        address indexed member,
        string indexed tDAOName,
        uint256 indexed couponAmount
    );
    event OnParentRewardTransferStatus(
        address indexed parent,
        uint256 indexed layer,
        address indexed child,
        uint256 reward,
        bool status
    );
    event OnMemberKYCVerified(address indexed member);
    event OnRefund(address indexed member, uint256 indexed amount);
    event OnUsdcAddressChanged(address indexed oldUsdc, address indexed newUsdc);
    event OnNewOperator(address indexed oldOperator, address indexed newOperator);
    event OnNewCouponPoolAddress(address indexed oldCouponPool, address indexed newCouponPool);
    event OnPrejoinDiscountSwitched(bool indexed preJoinDiscountEnabled);
    event OnRewardsDistributionSwitched(bool indexed rewardsEnabled);

    error ReferralGateway__ZeroAddress();
    error ReferralGateway__InvalidLaunchDate();
    error ReferralGateway__DAOAlreadyLaunched();
    error ReferralGateway__ZeroAmount();
    error ReferralGateway__InvalidContribution();
    error ReferralGateway__ParentMustKYCFirst();
    error ReferralGateway__AlreadyMember();
    error ReferralGateway__MemberAlreadyKYCed();
    error ReferralGateway__HasNotPaid();
    error ReferralGateway__NotKYCed();
    error ReferralGateway__tDAONotReadyYet();
    error ReferralGateway__NotEnoughFunds(uint256 amountToRefund, uint256 neededAmount);
    error ReferralGateway__NotAuthorizedCaller();
    error ReferralGateway__IncompatibleSettings();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _operator,
        address _KYCProvider,
        address _pauseGuardian,
        address _usdcAddress
    ) external initializer {
        _notZeroAddress(_operator);
        _notZeroAddress(_KYCProvider);
        _notZeroAddress(_pauseGuardian);
        _notZeroAddress(_usdcAddress);
        _initDependencies();

        _grantRoles(_operator, _KYCProvider, _pauseGuardian);

        operator = _operator;
        usdc = IERC20(_usdcAddress);
    }

    /*//////////////////////////////////////////////////////////////
                                  DAO
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create a new DAO
     * @param isPreJoinDiscountEnabled The pre-join status of the DAO
     * @param isReferralDiscountEnabled The referral discount status of the DAO
     * @param launchDate An estimated launch date of the DAO
     * @param objectiveAmount The objective amount of the DAO
     * @dev The launch date must be in seconds
     * @dev The launch date can be 0, if the DAO is already launched or the launch date is not defined
     * @dev The objective amount must be in USDC, six decimals
     * @dev The objective amount can be 0, if the DAO is already launched or the objective amount is not defined
     */
    function createDAO(
        bool isPreJoinDiscountEnabled,
        bool isReferralDiscountEnabled,
        uint256 launchDate,
        uint256 objectiveAmount
    ) external whenNotPaused onlyRole(OPERATOR) {
        require(launchDate > block.timestamp, ReferralGateway__InvalidLaunchDate());

        // Create the new DAO
        nameToDAOData[daoName].name = daoName;
        nameToDAOData[daoName].preJoinDiscountEnabled = isPreJoinDiscountEnabled;
        nameToDAOData[daoName].referralDiscountEnabled = isReferralDiscountEnabled;
        nameToDAOData[daoName].DAOAdmin = msg.sender;
        nameToDAOData[daoName].launchDate = launchDate;
        nameToDAOData[daoName].objectiveAmount = objectiveAmount;
        nameToDAOData[daoName].bmConsumer = address(0); // DEPRECATED!!!
        nameToDAOData[daoName].rewardsEnabled = true;

        emit OnNewDAO(
            isPreJoinDiscountEnabled,
            isReferralDiscountEnabled,
            launchDate,
            objectiveAmount
        );
    }

    /**
     * @notice Update the DAO estimated launch date
     */
    function updateLaunchDate(uint256 launchDate) external onlyRole(OPERATOR) {
        require(
            nameToDAOData[daoName].DAOAddress == address(0),
            ReferralGateway__DAOAlreadyLaunched()
        );
        nameToDAOData[daoName].launchDate = launchDate;

        emit OnDAOLaunchDateUpdated(launchDate);
    }

    /**
     * @notice Method to be called after a tDAO is deployed
     * @param tDAOAddress The address of the tDAO
     * @param isReferralDiscountEnabled The referral discount status of the DAO
     * @dev Only the DAOAdmin can call this method, the DAOAdmin is the one that created the DAO and must have
     *      the role of DAO_MULTISIG in the DAO
     * @dev The tDAOAddress must be different from 0
     * @dev It will disable the preJoinDiscountEnabled status of the DAO
     */
    function launchDAO(
        address tDAOAddress,
        address subscriptionModule,
        bool isReferralDiscountEnabled
    ) external onlyRole(OPERATOR) {
        _notZeroAddress(tDAOAddress);
        _notZeroAddress(subscriptionModule);
        require(
            nameToDAOData[daoName].DAOAddress == address(0),
            ReferralGateway__DAOAlreadyLaunched()
        );

        nameToDAOData[daoName].preJoinDiscountEnabled = false;
        nameToDAOData[daoName].referralDiscountEnabled = isReferralDiscountEnabled;
        nameToDAOData[daoName].DAOAddress = tDAOAddress;
        nameToDAOData[daoName].subscriptionModule = subscriptionModule;
        nameToDAOData[daoName].launchDate = block.timestamp;

        emit OnDAOLaunched(tDAOAddress);
    }

    /**
     * @notice Assign a rePool address to a tDAO name
     * @param rePoolAddress The address of the rePool
     */
    function enableRepool(address rePoolAddress) external onlyRole(OPERATOR) {
        _notZeroAddress(rePoolAddress);
        require(
            nameToDAOData[daoName].DAOAddress != address(0),
            ReferralGateway__tDAONotReadyYet()
        );
        nameToDAOData[daoName].rePoolAddress = rePoolAddress;

        emit OnRepoolEnabled(rePoolAddress);
    }

    function transferToRepool() external onlyRole(OPERATOR) {
        require(nameToDAOData[daoName].rePoolAddress != address(0), ReferralGateway__ZeroAddress());
        require(nameToDAOData[daoName].toRepool > 0, ReferralGateway__ZeroAmount());

        uint256 amount = nameToDAOData[daoName].toRepool;
        address rePoolAddress = nameToDAOData[daoName].rePoolAddress;

        nameToDAOData[daoName].toRepool = 0;

        usdc.safeTransfer(rePoolAddress, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 JOINS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pay a contribution to a DAO
     * @param contribution The amount of the contribution. In USDC six decimals
     * @param parent The address of the parent. Optional
     * @param newMember The address of the new member
     * @param couponAmount The amount of the coupon. In USDC six decimals
     * @dev The contribution must be between MINIMUM_CONTRIBUTION and MAXIMUM_CONTRIBUTION
     * @dev The function will create a prepaid member object with the contribution data if
     *      the DAO is not deployed yet, otherwise it will call the DAO to join
     * @dev It will apply the discounts and rewards if the DAO has the features enabled
     */
    function payContributionOnBehalfOf(
        uint256 contribution,
        address parent,
        address newMember,
        uint256 couponAmount,
        bool isDonated
    ) external onlyRole(COUPON_REDEEMER) returns (uint256 finalFee, uint256 discount) {
        if (isDonated)
            require(contribution == MINIMUM_CONTRIBUTION, ReferralGateway__InvalidContribution());

        require(couponAmount <= contribution, ReferralGateway__InvalidContribution());

        (finalFee, discount) = _payContribution(
            contribution,
            parent,
            newMember,
            couponAmount,
            isDonated
        );

        if (couponAmount > 0) {
            isMemberCouponRedeemer[newMember] = true;
            emit OnCouponRedeemed(newMember, daoName, couponAmount);
        }
    }

    /**
     * @notice Set the KYC status of a member
     * @param child The address of the member
     * @dev Only the KYC_PROVIDER can set the KYC status
     */
    function approveKYC(address child) external whenNotPaused onlyRole(KYC_PROVIDER) {
        _notZeroAddress(child);
        // Initial checks
        // Can not KYC a member that is already KYCed
        require(!isMemberKYCed[child], ReferralGateway__MemberAlreadyKYCed());

        // The member must have already pre-paid
        require(
            nameToDAOData[daoName].prepaidMembers[child].contributionBeforeFee != 0,
            ReferralGateway__HasNotPaid()
        );

        // Update the KYC status
        isMemberKYCed[child] = true;

        address parent = childToParent[child];

        for (uint256 i; i < uint256(MAX_TIER); ++i) {
            if (parent == address(0)) break;

            uint256 layer = i + 1;

            uint256 parentReward = nameToDAOData[daoName]
                .prepaidMembers[parent]
                .parentRewardsByChild[child];

            // Reset the rewards for this child
            nameToDAOData[daoName].prepaidMembers[parent].parentRewardsByChild[child] = 0;

            try usdc.transfer(parent, parentReward) {
                // Emit the event only if the transfer was successful
                emit OnParentRewardTransferStatus(parent, layer, child, parentReward, true);
            } catch {
                // If the transfer failed, we need to revert the rewards
                nameToDAOData[daoName].prepaidMembers[parent].parentRewardsByChild[
                    child
                ] = parentReward;

                // Emit an event for off-chain monitoring
                emit OnParentRewardTransferStatus(parent, layer, child, parentReward, false);
            }

            // We update the parent address to check the next parent
            parent = childToParent[parent];
        }

        emit OnMemberKYCVerified(child);
    }

    /**
     * @notice Join a tDAO
     * @param newMember The address of the new member
     * @dev The member must be KYCed
     * @dev The member must have a parent
     * @dev The member must have a tDAO assigned
     */
    function joinDAO(address newMember) external whenNotPaused nonReentrant {
        // Initial checks
        require(isMemberKYCed[newMember], ReferralGateway__NotKYCed());

        require(
            nameToDAOData[daoName].DAOAddress != address(0) &&
                nameToDAOData[daoName].launchDate <= block.timestamp,
            ReferralGateway__tDAONotReadyYet()
        );

        uint256 defaultMembershipDuration = 5 * (365 days);

        // Finally, we join the prepaidMember to the tDAO
        ISubscriptionModule(nameToDAOData[daoName].subscriptionModule).joinFromReferralGateway(
            newMember,
            childToParent[newMember],
            nameToDAOData[daoName].prepaidMembers[newMember].contributionBeforeFee,
            defaultMembershipDuration
        );

        usdc.safeTransfer(
            nameToDAOData[daoName].DAOAddress,
            nameToDAOData[daoName].prepaidMembers[newMember].contributionAfterFee
        );
    }

    /*//////////////////////////////////////////////////////////////
                                REFUNDS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Refund a prepaid member if the DAO is not deployed at launch date
     * @param member The address of the member
     * @dev Intended to be called by anyone if the DAO is not deployed at launch date
     */
    function refundIfDAOIsNotLaunched(address member) external {
        require(
            member == msg.sender || hasRole(OPERATOR, msg.sender),
            ReferralGateway__NotAuthorizedCaller()
        );
        require(
            nameToDAOData[daoName].launchDate < block.timestamp &&
                nameToDAOData[daoName].DAOAddress == address(0),
            ReferralGateway__tDAONotReadyYet()
        );

        _refund(member);
    }

    /**
     * @notice Refund a prepaid member if the DAO is not deployed at launch date
     * @param member The address of the member
     * @dev Intended to be called by the OPERATOR in spetial cases
     */
    function refundByAdmin(address member) external onlyRole(OPERATOR) {
        _refund(member);
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    function setNewOperator(address newOperator) external onlyRole(OPERATOR) {
        _notZeroAddress(newOperator);
        address oldOperator = operator;

        // Setting the new operator address
        operator = newOperator;

        // Fixing the roles
        _grantRole(OPERATOR, newOperator);
        _revokeRole(OPERATOR, msg.sender);

        usdc.safeTransferFrom(oldOperator, newOperator, usdc.balanceOf(oldOperator));

        emit OnNewOperator(oldOperator, newOperator);
    }

    function setCouponPoolAddress(address _couponPool) external onlyRole(OPERATOR) {
        _notZeroAddress(_couponPool);
        address oldCouponPool = couponPool;
        couponPool = _couponPool;
        emit OnNewCouponPoolAddress(oldCouponPool, _couponPool);
    }

    /**
     * @notice Switch the referralDiscount status of a DAO
     */
    function switchReferralDiscount() external onlyRole(OPERATOR) {
        nameToDAOData[daoName].referralDiscountEnabled = !nameToDAOData[daoName]
            .referralDiscountEnabled;

        emit OnReferralDiscountSwitched(nameToDAOData[daoName].referralDiscountEnabled);
    }

    function switchPrejoinDiscount() external onlyRole(OPERATOR) {
        nameToDAOData[daoName].preJoinDiscountEnabled = !nameToDAOData[daoName]
            .preJoinDiscountEnabled;
        emit OnPrejoinDiscountSwitched(nameToDAOData[daoName].preJoinDiscountEnabled);
    }

    function switchRewardsDistribution() external onlyRole(OPERATOR) {
        nameToDAOData[daoName].rewardsEnabled = !nameToDAOData[daoName].rewardsEnabled;
        emit OnRewardsDistributionSwitched(nameToDAOData[daoName].rewardsEnabled);
    }

    function pause() external onlyRole(PAUSE_GUARDIAN) {
        _pause();
    }

    function unpause() external onlyRole(PAUSE_GUARDIAN) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function getPrepaidMember(
        address member
    )
        external
        view
        returns (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 feeToOperator,
            uint256 discount
        )
    {
        contributionBeforeFee = nameToDAOData[daoName].prepaidMembers[member].contributionBeforeFee;
        contributionAfterFee = nameToDAOData[daoName].prepaidMembers[member].contributionAfterFee;
        feeToOperator = nameToDAOData[daoName].prepaidMembers[member].feeToOperator;
        discount = nameToDAOData[daoName].prepaidMembers[member].discount;
    }

    function getParentRewardsByChild(
        address parent,
        address child
    ) external view returns (uint256 rewards) {
        rewards = nameToDAOData[daoName].prepaidMembers[parent].parentRewardsByChild[child];
    }

    function getParentRewardsByLayer(
        address parent,
        uint256 layer
    ) external view returns (uint256 rewards) {
        rewards = nameToDAOData[daoName].prepaidMembers[parent].parentRewardsByLayer[layer];
    }

    function getDAOData()
        external
        view
        returns (
            bool preJoinDiscountEnabled,
            bool referralDiscountEnabled,
            bool rewardsEnabled,
            address DAOAdmin,
            address DAOAddress,
            uint256 launchDate,
            uint256 objectiveAmount,
            uint256 currentAmount,
            uint256 collectedFees,
            address rePoolAddress,
            uint256 toRepool,
            uint256 referralReserve
        )
    {
        preJoinDiscountEnabled = nameToDAOData[daoName].preJoinDiscountEnabled;
        referralDiscountEnabled = nameToDAOData[daoName].referralDiscountEnabled;
        rewardsEnabled = nameToDAOData[daoName].rewardsEnabled;
        DAOAdmin = nameToDAOData[daoName].DAOAdmin;
        DAOAddress = nameToDAOData[daoName].DAOAddress;
        launchDate = nameToDAOData[daoName].launchDate;
        objectiveAmount = nameToDAOData[daoName].objectiveAmount;
        currentAmount = nameToDAOData[daoName].currentAmount;
        collectedFees = nameToDAOData[daoName].collectedFees;
        rePoolAddress = nameToDAOData[daoName].rePoolAddress;
        toRepool = nameToDAOData[daoName].toRepool;
        referralReserve = nameToDAOData[daoName].referralReserve;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _initDependencies() internal {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuardTransient_init();
        __Pausable_init();
    }

    function _grantRoles(address _operator, address _KYCProvider, address _pauseGuardian) internal {
        _grantRole(DEFAULT_ADMIN_ROLE, _operator);
        _grantRole(OPERATOR, _operator);
        _grantRole(KYC_PROVIDER, _KYCProvider);
        _grantRole(PAUSE_GUARDIAN, _pauseGuardian);
    }

    function _payContribution(
        uint256 _contribution,
        address _parent,
        address _newMember,
        uint256 _couponAmount,
        bool _isDonated
    ) internal whenNotPaused nonReentrant returns (uint256 _finalFee, uint256 _discount) {
        uint256 normalizedContribution = (_contribution / DECIMAL_REQUIREMENT_PRECISION_USDC) *
            DECIMAL_REQUIREMENT_PRECISION_USDC;

        _payContributionChecks(normalizedContribution, _couponAmount, _parent, _newMember);

        _finalFee = (normalizedContribution * SERVICE_FEE_RATIO) / 100;

        // If the DAO pre join is enabled, it will get a discount as a pre-joiner
        if (nameToDAOData[daoName].preJoinDiscountEnabled)
            _discount +=
                ((normalizedContribution - _couponAmount) * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
                100;

        if (nameToDAOData[daoName].referralDiscountEnabled && _parent != address(0))
            _discount += ((normalizedContribution - _couponAmount) * REFERRAL_DISCOUNT_RATIO) / 100;

        // And if the DAO has the referral discount enabled, it will get a discount as a referrer
        uint256 toReferralReserve;

        if (nameToDAOData[daoName].rewardsEnabled) {
            toReferralReserve = (normalizedContribution * REFERRAL_RESERVE) / 100;

            // The discount will be only valid if the parent is valid
            if (_parent != address(0)) {
                childToParent[_newMember] = _parent;

                (_finalFee, nameToDAOData[daoName].referralReserve) = _parentRewards(
                    _newMember,
                    normalizedContribution,
                    nameToDAOData[daoName].referralReserve,
                    toReferralReserve,
                    _finalFee
                );
            } else {
                nameToDAOData[daoName].referralReserve += toReferralReserve;
            }
        }

        uint256 rePoolFee = (normalizedContribution * REPOOL_FEE_RATIO) / 100;

        _finalFee -= _discount + toReferralReserve + rePoolFee;

        assert(
            (normalizedContribution * SERVICE_FEE_RATIO) / 100 ==
                _finalFee + _discount + toReferralReserve + rePoolFee
        );

        nameToDAOData[daoName].toRepool += rePoolFee;
        nameToDAOData[daoName].currentAmount +=
            normalizedContribution -
            (normalizedContribution * SERVICE_FEE_RATIO) /
            100;
        nameToDAOData[daoName].collectedFees += _finalFee;

        uint256 amountToTransfer = normalizedContribution - _discount - _couponAmount;

        if (amountToTransfer > 0)
            usdc.safeTransferFrom(_newMember, address(this), amountToTransfer);

        if (_couponAmount > 0) usdc.safeTransferFrom(couponPool, address(this), _couponAmount);

        usdc.safeTransfer(operator, _finalFee);

        // Now we create the prepaid member object
        nameToDAOData[daoName].prepaidMembers[_newMember].member = _newMember;
        nameToDAOData[daoName]
            .prepaidMembers[_newMember]
            .contributionBeforeFee = normalizedContribution;
        nameToDAOData[daoName].prepaidMembers[_newMember].contributionAfterFee =
            normalizedContribution -
            (normalizedContribution * SERVICE_FEE_RATIO) /
            100;
        nameToDAOData[daoName].prepaidMembers[_newMember].feeToOperator = _finalFee;
        nameToDAOData[daoName].prepaidMembers[_newMember].discount = _discount;
        nameToDAOData[daoName].prepaidMembers[_newMember].isDonated = _isDonated;

        emit OnPrepayment(_parent, _newMember, normalizedContribution, _finalFee, _discount);
    }

    function _payContributionChecks(
        uint256 _contribution,
        uint256 _couponAmount,
        address _parent,
        address _newMember
    ) internal view {
        // The payer must be different than the zero address and cannot be already a member
        require(_newMember != address(0), ReferralGateway__ZeroAddress());
        require(
            nameToDAOData[daoName].prepaidMembers[_newMember].contributionBeforeFee == 0,
            ReferralGateway__AlreadyMember()
        );

        // If the member is valid, the contribution must be between the minimum and maximum contribution,
        // the same for the coupon amount, if any
        require(
            _contribution >= MINIMUM_CONTRIBUTION && _contribution <= MAXIMUM_CONTRIBUTION,
            ReferralGateway__InvalidContribution()
        );
        if (_couponAmount > 0)
            require(
                _couponAmount >= MINIMUM_CONTRIBUTION && _couponAmount <= MAXIMUM_CONTRIBUTION,
                ReferralGateway__InvalidContribution()
            );

        // If the referral discount is enabled, the rewards must also be enabled
        if (nameToDAOData[daoName].referralDiscountEnabled)
            require(nameToDAOData[daoName].rewardsEnabled, ReferralGateway__IncompatibleSettings());

        // If there is a parent, it must be KYCed first, and the rewards must be enabled
        if (_parent != address(0)) {
            require(nameToDAOData[daoName].rewardsEnabled, ReferralGateway__IncompatibleSettings());
            require(isMemberKYCed[_parent], ReferralGateway__ParentMustKYCFirst());
        }
    }

    function _parentRewards(
        address _initialChildToCheck,
        uint256 _contribution,
        uint256 _currentReferralReserve,
        uint256 _toReferralReserve,
        uint256 _currentFee
    ) internal returns (uint256, uint256) {
        address currentChildToCheck = _initialChildToCheck;
        uint256 newReferralReserveBalance = _currentReferralReserve + _toReferralReserve;
        uint256 parentRewardsAccumulated;

        for (int256 i; i < MAX_TIER; ++i) {
            if (childToParent[currentChildToCheck] == address(0)) {
                break;
            }

            nameToDAOData[daoName]
                .prepaidMembers[childToParent[currentChildToCheck]]
                .parentRewardsByChild[_initialChildToCheck] =
                (_contribution * _referralRewardRatioByLayer(i + 1)) /
                (100 * DECIMAL_CORRECTION);

            nameToDAOData[daoName]
                .prepaidMembers[childToParent[currentChildToCheck]]
                .parentRewardsByLayer[uint256(i + 1)] +=
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

    /**
     * @notice This function calculates the referral reward ratio based on the layer
     * @param _layer The layer of the referral
     * @return referralRewardRatio_ The referral reward ratio
     * @dev Max Layer = 4
     * @dev The formula is y = Ax^3 + Bx^2 + Cx + D
     *      y = reward ratio, x = layer, A = -3_125, B = 30_500, C = -99_625, D = 112_250
     *      The original values are layer 1 = 4%, layer 2 = 1%, layer 3 = 0.35%, layer 4 = 0.175%
     *      But this values where multiplied by 10_000 to avoid decimals in the formula so the values are
     *      layer 1 = 40_000, layer 2 = 10_000, layer 3 = 3_500, layer 4 = 1_750
     */
    function _referralRewardRatioByLayer(
        int256 _layer
    ) internal pure returns (uint256 referralRewardRatio_) {
        assembly {
            let layerSquare := mul(_layer, _layer) // x^2
            let layerCube := mul(_layer, layerSquare) // x^3

            // y = Ax^3 + Bx^2 + Cx + D
            referralRewardRatio_ := add(
                add(add(mul(A, layerCube), mul(B, layerSquare)), mul(C, _layer)),
                D
            )
        }
    }

    function _refund(address _member) internal {
        require(
            nameToDAOData[daoName].prepaidMembers[_member].contributionBeforeFee != 0,
            ReferralGateway__HasNotPaid()
        );

        uint256 discountReceived = nameToDAOData[daoName].prepaidMembers[_member].discount;

        uint256 amountToRefund = nameToDAOData[daoName]
            .prepaidMembers[_member]
            .contributionBeforeFee - discountReceived;

        require(
            amountToRefund <= usdc.balanceOf(address(this)),
            ReferralGateway__NotEnoughFunds(amountToRefund, usdc.balanceOf(address(this)))
        );

        uint256 leftover = amountToRefund;

        // We deduct first from the tDAO currentAmount only the part the member contributed
        nameToDAOData[daoName].currentAmount -= nameToDAOData[daoName]
            .prepaidMembers[_member]
            .contributionAfterFee;

        // We update the leftover amount
        leftover -= nameToDAOData[daoName].prepaidMembers[_member].contributionAfterFee;

        // We compare now against the referralReserve
        if (leftover <= nameToDAOData[daoName].referralReserve) {
            // If it is enough we deduct the leftover from the referralReserve
            nameToDAOData[daoName].referralReserve -= leftover;
        } else {
            // We update the leftover value and set the referralReserve to 0
            leftover -= nameToDAOData[daoName].referralReserve;
            nameToDAOData[daoName].referralReserve = 0;

            // We compare now against the repool amount
            if (leftover <= nameToDAOData[daoName].toRepool) {
                nameToDAOData[daoName].toRepool -= leftover;
            } else {
                nameToDAOData[daoName].toRepool = 0;
            }
        }

        delete nameToDAOData[daoName].prepaidMembers[_member];

        isMemberKYCed[_member] = false;

        if (isMemberCouponRedeemer[_member]) {
            // Reset the coupon redeemer status, this way the member can redeem again
            isMemberCouponRedeemer[_member] = false;
            // We transfer the coupon amount to the coupon pool
            usdc.safeTransfer(couponPool, amountToRefund);
        } else {
            // We transfer the amount to the member
            usdc.safeTransfer(_member, amountToRefund);
        }

        emit OnRefund(_member, amountToRefund);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(OPERATOR) {}

    function _notZeroAddress(address _address) internal pure {
        require(_address != address(0), ReferralGateway__ZeroAddress());
    }
}
