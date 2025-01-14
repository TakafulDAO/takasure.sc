// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title ReferralGateway
 * @author Maikel Ordaz
 * @dev This contract will manage all the functionalities related to the referral system and pre-joins
 *      to the LifeDAO protocol
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITakasurePool} from "contracts/interfaces/ITakasurePool.sol";
import {IBenefitMultiplierConsumer} from "contracts/interfaces/IBenefitMultiplierConsumer.sol";

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
    IBenefitMultiplierConsumer private bmConsumer;

    address private operator;

    mapping(string tDAOName => tDAO DAOData) private nameToDAOData;
    mapping(address member => bool) public isMemberKYCed;
    mapping(address child => address parent) public childToParent;

    address private couponPool;
    address private ccipReceiverContract;

    struct PrepaidMember {
        address member;
        uint256 contributionBeforeFee;
        uint256 contributionAfterFee;
        uint256 feeToOperator; // Fee after all the discounts and rewards
        uint256 discount;
        mapping(address child => uint256 rewards) parentRewardsByChild;
        mapping(uint256 layer => uint256 rewards) parentRewardsByLayer;
    }

    struct tDAO {
        mapping(address member => PrepaidMember) prepaidMembers;
        string name;
        bool preJoinEnabled;
        bool referralDiscount;
        address DAOAdmin; // The one that can modify the DAO settings
        address DAOAddress; // To be assigned when the tDAO is deployed
        uint256 launchDate; // In seconds. An estimated launch date of the DAO
        uint256 objectiveAmount; // In USDC, six decimals
        uint256 currentAmount; // In USDC, six decimals
        uint256 collectedFees; // Fees collected after deduct, discounts, referral reserve and repool amounts. In USDC, six decimals
        address rePoolAddress; // To be assigned when the tDAO is deployed
        uint256 toRepool; // In USDC, six decimals
        uint256 referralReserve; // In USDC, six decimals
        IBenefitMultiplierConsumer bmConsumer;
    }

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
        string indexed DAOName,
        bool indexed preJoinEnabled,
        bool indexed referralDiscount,
        uint256 launchDate,
        uint256 objectiveAmount
    );
    event OnDAOLaunchDateUpdated(string indexed DAOName, uint256 indexed launchDate);
    event OnDAOLaunched(string indexed DAOName, address indexed DAOAddress);
    event OnReferralDiscountSwitched(string indexed DAOName, bool indexed referralDiscount);
    event OnRepoolEnabled(string indexed DAOName, address indexed rePoolAddress);
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
    event OnParentRewarded(
        address indexed parent,
        uint256 indexed layer,
        address indexed child,
        uint256 reward
    );
    event OnMemberKYCVerified(address indexed member);
    event OnBenefitMultiplierConsumerChanged(
        string indexed tDAOName,
        address indexed newBenefitMultiplierConsumer,
        address indexed oldBenefitMultiplierConsumer
    );
    event OnRefund(string indexed tDAOName, address indexed member, uint256 indexed amount);
    event OnUsdcAddressChanged(address indexed oldUsdc, address indexed newUsdc);
    event OnNewOperator(address indexed oldOperator, address indexed newOperator);
    event OnNewCouponPoolAddress(address indexed oldCouponPool, address indexed newCouponPool);
    event OnNewCCIPReceiverContract(
        address indexed oldCCIPReceiverContract,
        address indexed newCCIPReceiverContract
    );

    error ReferralGateway__ZeroAddress();
    error ReferralGateway__onlyDAOAdmin();
    error ReferralGateway__MustHaveName();
    error ReferralGateway__InvalidLaunchDate();
    error ReferralGateway__AlreadyExists();
    error ReferralGateway__DAOAlreadyLaunched();
    error ReferralGateway__ZeroAmount();
    error ReferralGateway__ContributionOutOfRange();
    error ReferralGateway__ParentMustKYCFirst();
    error ReferralGateway__AlreadyMember();
    error ReferralGateway__MemberAlreadyKYCed();
    error ReferralGateway__HasNotPaid();
    error ReferralGateway__NotKYCed();
    error ReferralGateway__tDAONotReadyYet();
    error ReferralGateway__NotEnoughFunds(uint256 amountToRefund, uint256 neededAmount);
    error ReferralGateway__WrongCaller();

    modifier notZeroAddress(address _address) {
        require(_address != address(0), ReferralGateway__ZeroAddress());
        _;
    }

    modifier onlyDAOAdmin(string calldata tDAOName) {
        require(nameToDAOData[tDAOName].DAOAdmin == msg.sender, ReferralGateway__onlyDAOAdmin());
        _;
    }

    modifier onlyCouponRedeemerOrCcipReceiver() {
        require(
            hasRole(COUPON_REDEEMER, msg.sender) || msg.sender == ccipReceiverContract,
            ReferralGateway__WrongCaller()
        );
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _operator,
        address _KYCProvider,
        address _pauseGuardian,
        address _usdcAddress,
        address _benefitMultiplierConsumer
    )
        external
        notZeroAddress(_operator)
        notZeroAddress(_KYCProvider)
        notZeroAddress(_pauseGuardian)
        notZeroAddress(_usdcAddress)
        notZeroAddress(_benefitMultiplierConsumer)
        initializer
    {
        _initDependencies();

        _grantRoles(_operator, _KYCProvider, _pauseGuardian);

        operator = _operator;
        usdc = IERC20(_usdcAddress);
    }

    /*//////////////////////////////////////////////////////////////
                               DAO ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create a new DAO
     * @param DAOName The name of the DAO
     * @param isPreJoinEnabled The pre-join status of the DAO
     * @param isReferralDiscountEnabled The referral discount status of the DAO
     * @param launchDate An estimated launch date of the DAO
     * @param objectiveAmount The objective amount of the DAO
     * @dev The launch date must be in seconds
     * @dev The launch date can be 0, if the DAO is already launched or the launch date is not defined
     * @dev The objective amount must be in USDC, six decimals
     * @dev The objective amount can be 0, if the DAO is already launched or the objective amount is not defined
     */
    function createDAO(
        string calldata DAOName,
        bool isPreJoinEnabled,
        bool isReferralDiscountEnabled,
        uint256 launchDate,
        uint256 objectiveAmount,
        address _bmConsumer
    ) external whenNotPaused onlyRole(OPERATOR) {
        require(bytes(DAOName).length != 0, ReferralGateway__MustHaveName());
        require(
            !(Strings.equal(nameToDAOData[DAOName].name, DAOName)),
            ReferralGateway__AlreadyExists()
        );
        require(launchDate > block.timestamp, ReferralGateway__InvalidLaunchDate());

        // Create the new DAO
        nameToDAOData[DAOName].name = DAOName;
        nameToDAOData[DAOName].preJoinEnabled = isPreJoinEnabled;
        nameToDAOData[DAOName].referralDiscount = isReferralDiscountEnabled;
        nameToDAOData[DAOName].DAOAdmin = msg.sender;
        nameToDAOData[DAOName].launchDate = launchDate;
        nameToDAOData[DAOName].objectiveAmount = objectiveAmount;
        nameToDAOData[DAOName].bmConsumer = IBenefitMultiplierConsumer(_bmConsumer);

        emit OnNewDAO(
            DAOName,
            isPreJoinEnabled,
            isReferralDiscountEnabled,
            launchDate,
            objectiveAmount
        );
    }

    /**
     * @notice Update the DAO estimated launch date
     */
    function updateLaunchDate(
        string calldata tDAOName,
        uint256 launchDate
    ) external onlyDAOAdmin(tDAOName) {
        require(
            nameToDAOData[tDAOName].DAOAddress == address(0),
            ReferralGateway__DAOAlreadyLaunched()
        );
        nameToDAOData[tDAOName].launchDate = launchDate;

        emit OnDAOLaunchDateUpdated(tDAOName, launchDate);
    }

    /**
     * @notice Method to be called after a tDAO is deployed
     * @param tDAOName The name of the tDAO
     * @param tDAOAddress The address of the tDAO
     * @param isReferralDiscountEnabled The referral discount status of the DAO
     * @dev Only the DAOAdmin can call this method, the DAOAdmin is the one that created the DAO and must have
     *      the role of DAO_MULTISIG in the DAO
     * @dev The tDAOAddress must be different from 0
     * @dev It will disable the preJoinEnabled status of the DAO
     */
    function launchDAO(
        string calldata tDAOName,
        address tDAOAddress,
        bool isReferralDiscountEnabled
    ) external onlyDAOAdmin(tDAOName) notZeroAddress(tDAOAddress) {
        require(
            ITakasurePool(tDAOAddress).hasRole(keccak256("DAO_MULTISIG"), msg.sender),
            ReferralGateway__onlyDAOAdmin()
        );
        require(
            nameToDAOData[tDAOName].DAOAddress == address(0),
            ReferralGateway__DAOAlreadyLaunched()
        );

        nameToDAOData[tDAOName].preJoinEnabled = false;
        nameToDAOData[tDAOName].referralDiscount = isReferralDiscountEnabled;
        nameToDAOData[tDAOName].DAOAddress = tDAOAddress;
        nameToDAOData[tDAOName].launchDate = block.timestamp;

        emit OnDAOLaunched(tDAOName, tDAOAddress);
    }

    /**
     * @notice Switch the referralDiscount status of a DAO
     */
    function switchReferralDiscount(string calldata tDAOName) external onlyDAOAdmin(tDAOName) {
        nameToDAOData[tDAOName].referralDiscount = !nameToDAOData[tDAOName].referralDiscount;

        emit OnReferralDiscountSwitched(tDAOName, nameToDAOData[tDAOName].referralDiscount);
    }

    /**
     * @notice Assign a rePool address to a tDAO name
     * @param tDAOName The name of the tDAO
     * @param rePoolAddress The address of the rePool
     */
    function enableRepool(
        string calldata tDAOName,
        address rePoolAddress
    ) external notZeroAddress(rePoolAddress) onlyDAOAdmin(tDAOName) {
        require(
            nameToDAOData[tDAOName].DAOAddress != address(0),
            ReferralGateway__tDAONotReadyYet()
        );
        nameToDAOData[tDAOName].rePoolAddress = rePoolAddress;

        emit OnRepoolEnabled(tDAOName, rePoolAddress);
    }

    function transferToRepool(string calldata tDAOName) external onlyDAOAdmin(tDAOName) {
        require(
            nameToDAOData[tDAOName].rePoolAddress != address(0),
            ReferralGateway__ZeroAddress()
        );
        require(nameToDAOData[tDAOName].toRepool > 0, ReferralGateway__ZeroAmount());

        uint256 amount = nameToDAOData[tDAOName].toRepool;
        address rePoolAddress = nameToDAOData[tDAOName].rePoolAddress;

        nameToDAOData[tDAOName].toRepool = 0;

        usdc.safeTransfer(rePoolAddress, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 JOINS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pay a contribution to a DAO
     * @param contribution The amount of the contribution. In USDC six decimals
     * @param tDAOName The name of the DAO
     * @param parent The address of the parent. Optional
     * @dev The contribution must be between MINIMUM_CONTRIBUTION and MAXIMUM_CONTRIBUTION
     * @dev The function will create a prepaid member object with the contribution data if
     *      the DAO is not deployed yet, otherwise it will call the DAO to join
     * @dev It will apply the discounts and rewards if the DAO has the features enabled
     */
    function payContribution(
        uint256 contribution,
        string calldata tDAOName,
        address parent
    ) external returns (uint256 finalFee, uint256 discount) {
        (finalFee, discount) = _payContribution(contribution, tDAOName, parent, msg.sender, 0);
    }

    /**
     * @notice Pay a contribution to a DAO
     * @param contribution The amount of the contribution. In USDC six decimals
     * @param tDAOName The name of the DAO
     * @param parent The address of the parent. Optional
     * @param newMember The address of the new member
     * @param couponAmount The amount of the coupon. In USDC six decimals
     * @dev The contribution must be between MINIMUM_CONTRIBUTION and MAXIMUM_CONTRIBUTION
     * @dev The function will create a prepaid member object with the contribution data if
     *      the DAO is not deployed yet, otherwise it will call the DAO to join
     * @dev It will apply the discounts and rewards if the DAO has the features enabled
     * @dev It can be call by the coupon redeemer if the payment comes from the same blockchain
     * @dev It can be call by the ccipReceiverContract if the payment comes from another blockchain
     */
    function payContributionOnBehalfOf(
        uint256 contribution,
        string calldata tDAOName,
        address parent,
        address newMember,
        uint256 couponAmount
    ) external onlyCouponRedeemerOrCcipReceiver returns (uint256 finalFee, uint256 discount) {
        (finalFee, discount) = _payContribution(
            contribution,
            tDAOName,
            parent,
            newMember,
            couponAmount
        );

        if (couponAmount > 0) emit OnCouponRedeemed(newMember, tDAOName, couponAmount);
    }

    /**
     * @notice Set the KYC status of a member
     * @param child The address of the member
     * @dev Only the KYC_PROVIDER can set the KYC status
     */
    function setKYCStatus(
        address child,
        string calldata tDAOName
    ) external whenNotPaused notZeroAddress(child) onlyRole(KYC_PROVIDER) {
        // Initial checks
        // Can not KYC a member that is already KYCed
        require(!isMemberKYCed[child], ReferralGateway__MemberAlreadyKYCed());

        // The member must have already pre-paid
        require(
            nameToDAOData[tDAOName].prepaidMembers[child].contributionBeforeFee != 0,
            ReferralGateway__HasNotPaid()
        );

        // Update the KYC status
        isMemberKYCed[child] = true;

        address parent = childToParent[child];

        for (uint256 i; i < uint256(MAX_TIER); ++i) {
            if (parent == address(0)) break;

            uint256 layer = i + 1;

            uint256 parentReward = nameToDAOData[tDAOName]
                .prepaidMembers[parent]
                .parentRewardsByChild[child];

            // Reset the rewards for this child
            nameToDAOData[tDAOName].prepaidMembers[parent].parentRewardsByChild[child] = 0;

            usdc.safeTransfer(parent, parentReward);

            emit OnParentRewarded(parent, layer, child, parentReward);

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
    function joinDAO(
        address newMember,
        string calldata tDAOName
    ) external whenNotPaused nonReentrant {
        // Initial checks
        require(isMemberKYCed[newMember], ReferralGateway__NotKYCed());

        require(
            nameToDAOData[tDAOName].DAOAddress != address(0) &&
                nameToDAOData[tDAOName].launchDate <= block.timestamp,
            ReferralGateway__tDAONotReadyYet()
        );

        // Finally, we join the prepaidMember to the tDAO
        ITakasurePool(nameToDAOData[tDAOName].DAOAddress).prejoins(
            newMember,
            nameToDAOData[tDAOName].prepaidMembers[newMember].contributionBeforeFee,
            nameToDAOData[tDAOName].prepaidMembers[newMember].contributionAfterFee
        );

        usdc.safeTransfer(
            nameToDAOData[tDAOName].DAOAddress,
            nameToDAOData[tDAOName].prepaidMembers[newMember].contributionAfterFee
        );
    }

    /*//////////////////////////////////////////////////////////////
                                REFUNDS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Refund a prepaid member if the DAO is not deployed at launch date
     * @param member The address of the member
     * @param tDAOName The name of the DAO
     * @dev Intended to be called by anyone if the DAO is not deployed at launch date
     */
    function refundIfDAOIsNotLaunched(address member, string calldata tDAOName) external {
        require(
            nameToDAOData[tDAOName].launchDate < block.timestamp &&
                nameToDAOData[tDAOName].DAOAddress == address(0),
            ReferralGateway__tDAONotReadyYet()
        );

        _refund(member, tDAOName);
    }

    /**
     * @notice Refund a prepaid member if the DAO is not deployed at launch date
     * @param member The address of the member
     * @param tDAOName The name of the DAO
     * @dev Intended to be called by the OPERATOR in spetial cases
     */
    function refundByAdmin(address member, string calldata tDAOName) external onlyRole(OPERATOR) {
        _refund(member, tDAOName);
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    function setUsdcAddress(address _usdcAddress) external onlyRole(OPERATOR) {
        address oldUsdc = address(usdc);
        usdc = IERC20(_usdcAddress);

        emit OnUsdcAddressChanged(oldUsdc, _usdcAddress);
    }

    function setNewBenefitMultiplierConsumer(
        address newBenefitMultiplierConsumer,
        string calldata tDAOName
    ) external onlyRole(OPERATOR) notZeroAddress(newBenefitMultiplierConsumer) {
        address oldBenefitMultiplierConsumer = address(nameToDAOData[tDAOName].bmConsumer);
        nameToDAOData[tDAOName].bmConsumer = IBenefitMultiplierConsumer(
            newBenefitMultiplierConsumer
        );

        emit OnBenefitMultiplierConsumerChanged(
            tDAOName,
            newBenefitMultiplierConsumer,
            oldBenefitMultiplierConsumer
        );
    }

    function setNewOperator(
        address newOperator
    ) external notZeroAddress(newOperator) onlyRole(OPERATOR) {
        address oldOperator = operator;

        // Setting the new operator address
        operator = newOperator;

        // Fixing the roles
        _grantRole(OPERATOR, newOperator);
        _revokeRole(OPERATOR, msg.sender);

        usdc.safeTransferFrom(oldOperator, newOperator, usdc.balanceOf(oldOperator));

        emit OnNewOperator(oldOperator, newOperator);
    }

    function setCouponPoolAddress(
        address _couponPool
    ) external notZeroAddress(_couponPool) onlyRole(OPERATOR) {
        address oldCouponPool = couponPool;
        couponPool = _couponPool;
        emit OnNewCouponPoolAddress(oldCouponPool, _couponPool);
    }

    function setCCIPReceiverContract(
        address _ccipReceiverContract
    ) external notZeroAddress(_ccipReceiverContract) onlyRole(OPERATOR) {
        address oldCCIPReceiverContract = ccipReceiverContract;
        ccipReceiverContract = _ccipReceiverContract;
        emit OnNewCCIPReceiverContract(oldCCIPReceiverContract, _ccipReceiverContract);
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
        address member,
        string calldata tDAOName
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
        contributionBeforeFee = nameToDAOData[tDAOName]
            .prepaidMembers[member]
            .contributionBeforeFee;
        contributionAfterFee = nameToDAOData[tDAOName].prepaidMembers[member].contributionAfterFee;
        feeToOperator = nameToDAOData[tDAOName].prepaidMembers[member].feeToOperator;
        discount = nameToDAOData[tDAOName].prepaidMembers[member].discount;
    }

    function getParentRewardsByChild(
        address parent,
        address child,
        string calldata tDAOName
    ) external view returns (uint256 rewards) {
        rewards = nameToDAOData[tDAOName].prepaidMembers[parent].parentRewardsByChild[child];
    }

    function getParentRewardsByLayer(
        address parent,
        uint256 layer,
        string calldata tDAOName
    ) external view returns (uint256 rewards) {
        rewards = nameToDAOData[tDAOName].prepaidMembers[parent].parentRewardsByLayer[layer];
    }

    function getDAOData(
        string calldata tDAOName
    )
        external
        view
        returns (
            bool preJoinEnabled,
            bool referralDiscount,
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
        preJoinEnabled = nameToDAOData[tDAOName].preJoinEnabled;
        referralDiscount = nameToDAOData[tDAOName].referralDiscount;
        DAOAdmin = nameToDAOData[tDAOName].DAOAdmin;
        DAOAddress = nameToDAOData[tDAOName].DAOAddress;
        launchDate = nameToDAOData[tDAOName].launchDate;
        objectiveAmount = nameToDAOData[tDAOName].objectiveAmount;
        currentAmount = nameToDAOData[tDAOName].currentAmount;
        collectedFees = nameToDAOData[tDAOName].collectedFees;
        rePoolAddress = nameToDAOData[tDAOName].rePoolAddress;
        toRepool = nameToDAOData[tDAOName].toRepool;
        referralReserve = nameToDAOData[tDAOName].referralReserve;
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

    function _getBenefitMultiplierFromOracle(string calldata _tDAOName, address _member) internal {
        string memory memberAddressToString = Strings.toHexString(uint256(uint160(_member)), 20);
        string[] memory args = new string[](1);
        args[0] = memberAddressToString;
        nameToDAOData[_tDAOName].bmConsumer.sendRequest(args);
    }

    function _payContribution(
        uint256 _contribution,
        string calldata _tDAOName,
        address _parent,
        address _newMember,
        uint256 _couponAmount
    ) internal whenNotPaused nonReentrant returns (uint256 _finalFee, uint256 _discount) {
        uint256 realContribution;

        if (_couponAmount > _contribution) realContribution = _couponAmount;
        else realContribution = _contribution;

        _payContributionChecks(realContribution, _tDAOName, _parent, _newMember);

        _finalFee = (realContribution * SERVICE_FEE_RATIO) / 100;
        // If the DAO pre join is enabled it means the DAO is not deployed yet
        if (nameToDAOData[_tDAOName].preJoinEnabled) {
            // The prepaid member object is created inside this if statement only

            // It will get a discount as a pre-joiner
            _discount +=
                ((realContribution - _couponAmount) * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
                100;
            uint256 toReferralReserve;

            if (nameToDAOData[_tDAOName].referralDiscount) {
                toReferralReserve = (realContribution * REFERRAL_RESERVE) / 100;

                if (_parent != address(0)) {
                    uint256 referralDiscount = ((realContribution - _couponAmount) *
                        REFERRAL_DISCOUNT_RATIO) / 100;
                    _discount += referralDiscount;

                    childToParent[_newMember] = _parent;

                    (_finalFee, nameToDAOData[_tDAOName].referralReserve) = _parentRewards(
                        _newMember,
                        realContribution,
                        nameToDAOData[_tDAOName].referralReserve,
                        toReferralReserve,
                        _finalFee,
                        _tDAOName
                    );
                } else {
                    nameToDAOData[_tDAOName].referralReserve += toReferralReserve;
                }
            }

            uint256 rePoolFee = (realContribution * REPOOL_FEE_RATIO) / 100;

            _finalFee -= _discount + toReferralReserve + rePoolFee;

            assert(
                (realContribution * SERVICE_FEE_RATIO) / 100 ==
                    _finalFee + _discount + toReferralReserve + rePoolFee
            );

            nameToDAOData[_tDAOName].toRepool += rePoolFee;
            nameToDAOData[_tDAOName].currentAmount +=
                realContribution -
                (realContribution * SERVICE_FEE_RATIO) /
                100;
            nameToDAOData[_tDAOName].collectedFees += _finalFee;

            uint256 amountToTransfer = realContribution - _discount - _couponAmount;

            if (amountToTransfer > 0) {
                if (msg.sender == ccipReceiverContract) {
                    usdc.safeTransferFrom(ccipReceiverContract, address(this), amountToTransfer);
                } else {
                    usdc.safeTransferFrom(_newMember, address(this), amountToTransfer);
                }
            }

            if (_couponAmount > 0) {
                usdc.safeTransferFrom(couponPool, address(this), _couponAmount);
            }

            usdc.safeTransfer(operator, _finalFee);

            nameToDAOData[_tDAOName].prepaidMembers[_newMember].member = _newMember;
            nameToDAOData[_tDAOName]
                .prepaidMembers[_newMember]
                .contributionBeforeFee = realContribution;
            nameToDAOData[_tDAOName].prepaidMembers[_newMember].contributionAfterFee =
                realContribution -
                (realContribution * SERVICE_FEE_RATIO) /
                100;
            nameToDAOData[_tDAOName].prepaidMembers[_newMember].feeToOperator = _finalFee;
            nameToDAOData[_tDAOName].prepaidMembers[_newMember].discount = _discount;

            // Finally, we request the benefit multiplier for the member, this to have it ready when the member joins the DAO
            _getBenefitMultiplierFromOracle(_tDAOName, _newMember);

            emit OnPrepayment(_parent, _newMember, realContribution, _finalFee, _discount);
        } else {
            /**
             * Call the DAO to join
             *  TODO: This call needs to change the joinPool function to add a param for the new member
             *  TODO: To Implement call the function in the router. For V2 of this contract
             */
        }
    }

    function _payContributionChecks(
        uint256 _contribution,
        string calldata _tDAOName,
        address _parent,
        address _newMember
    ) internal view {
        // DAO must exist
        require(
            nameToDAOData[_tDAOName].preJoinEnabled ||
                nameToDAOData[_tDAOName].DAOAddress != address(0),
            ReferralGateway__tDAONotReadyYet()
        );

        require(
            _contribution >= MINIMUM_CONTRIBUTION && _contribution <= MAXIMUM_CONTRIBUTION,
            ReferralGateway__ContributionOutOfRange()
        );

        if (_parent != address(0))
            require(isMemberKYCed[_parent], ReferralGateway__ParentMustKYCFirst());

        if (nameToDAOData[_tDAOName].preJoinEnabled) {
            // We check if the member already exists
            require(
                nameToDAOData[_tDAOName].prepaidMembers[_newMember].contributionBeforeFee == 0,
                ReferralGateway__AlreadyMember()
            );
        }
    }

    function _parentRewards(
        address _initialChildToCheck,
        uint256 _contribution,
        uint256 _currentReferralReserve,
        uint256 _toReferralReserve,
        uint256 _currentFee,
        string calldata _tDAOName
    ) internal returns (uint256, uint256) {
        address currentChildToCheck = _initialChildToCheck;
        uint256 newReferralReserveBalance = _currentReferralReserve + _toReferralReserve;
        uint256 parentRewardsAccumulated;

        for (int256 i; i < MAX_TIER; ++i) {
            if (childToParent[currentChildToCheck] == address(0)) {
                break;
            }

            nameToDAOData[_tDAOName]
                .prepaidMembers[childToParent[currentChildToCheck]]
                .parentRewardsByChild[_initialChildToCheck] =
                (_contribution * _referralRewardRatioByLayer(i + 1)) /
                (100 * DECIMAL_CORRECTION);

            nameToDAOData[_tDAOName]
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

    function _refund(address _member, string calldata _tDAOName) internal {
        require(
            nameToDAOData[_tDAOName].prepaidMembers[_member].contributionBeforeFee != 0,
            ReferralGateway__HasNotPaid()
        );

        uint256 discountReceived = nameToDAOData[_tDAOName].prepaidMembers[_member].discount;

        uint256 amountToRefund = nameToDAOData[_tDAOName]
            .prepaidMembers[_member]
            .contributionBeforeFee - discountReceived;

        require(
            amountToRefund <= usdc.balanceOf(address(this)),
            ReferralGateway__NotEnoughFunds(amountToRefund, usdc.balanceOf(address(this)))
        );

        uint256 leftover = amountToRefund;

        // We deduct first from the tDAO currentAmount only the part the member contributed
        nameToDAOData[_tDAOName].currentAmount -= nameToDAOData[_tDAOName]
            .prepaidMembers[_member]
            .contributionAfterFee;

        // We update the leftover amount
        leftover -= nameToDAOData[_tDAOName].prepaidMembers[_member].contributionAfterFee;

        // We compare now against the referralReserve
        if (leftover <= nameToDAOData[_tDAOName].referralReserve) {
            // If it is enough we deduct the leftover from the referralReserve
            nameToDAOData[_tDAOName].referralReserve -= leftover;
        } else {
            // We update the leftover value and set the referralReserve to 0
            leftover -= nameToDAOData[_tDAOName].referralReserve;
            nameToDAOData[_tDAOName].referralReserve = 0;

            // We compare now against the repool amount
            if (leftover <= nameToDAOData[_tDAOName].toRepool) {
                nameToDAOData[_tDAOName].toRepool -= leftover;
            } else {
                nameToDAOData[_tDAOName].toRepool = 0;
            }
        }

        delete nameToDAOData[_tDAOName].prepaidMembers[_member];

        isMemberKYCed[_member] = false;

        usdc.safeTransfer(_member, amountToRefund);

        emit OnRefund(_tDAOName, _member, amountToRefund);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(OPERATOR) {}
}
