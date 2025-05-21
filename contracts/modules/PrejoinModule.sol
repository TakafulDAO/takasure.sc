// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title PrejoinModule
 * @author Maikel Ordaz
 * @dev This contract will manage all the functionalities related to the pre-joins to the LifeDAO protocol
 * @dev Important notes:
 *      1. When the dao is launched the prejoin feature will be disabled
 *      2. After the DAO is launched the user will have to join the DAO manually
 *      3. After every user joins the DAO, those ones that did not KYC will be refunded
 *      4. After all this, the module will be disabled
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {IBenefitMultiplierConsumer} from "contracts/interfaces/IBenefitMultiplierConsumer.sol";
import {IEntryModule} from "contracts/interfaces/IEntryModule.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {ParentRewards} from "contracts/helpers/payments/ParentRewards.sol";
import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";
import {ReserveAndMemberValuesHook} from "contracts/hooks/ReserveAndMemberValuesHook.sol";

import {tDAO, ModuleState, Reserve} from "contracts/types/TakasureTypes.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";

pragma solidity 0.8.28;

/// @custom:oz-upgrades-from contracts/version_previous_contracts/ReferralGatewayV1.sol:ReferralGatewayV1
contract PrejoinModule is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    ParentRewards,
    TLDModuleImplementation,
    ReserveAndMemberValuesHook
{
    using SafeERC20 for IERC20;

    IERC20 public usdc;
    IBenefitMultiplierConsumer private bmConsumer;

    string private constant DAO_NAME = "The LifeDAO";

    address private operator;

    mapping(string tDAOName => tDAO DAOData) private nameToDAOData;
    mapping(address member => bool) public isMemberKYCed;
    mapping(address child => address parent) public childToParent;

    address private couponPool;
    address private ccipReceiverContract;

    ModuleState private moduleState;

    // Set to true when new members use coupons to pay their contributions. It does not matter the amount
    mapping(address member => bool) private isMemberCouponRedeemer;

    /*//////////////////////////////////////////////////////////////
                              FIXED RATIOS
    //////////////////////////////////////////////////////////////*/

    uint8 private constant SERVICE_FEE_RATIO = 27;
    uint256 private constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee
    uint256 private constant REPOOL_FEE_RATIO = 2; // 2% of contribution deducted from fee
    uint256 private constant MINIMUM_CONTRIBUTION = 25e6; // 25 USDC
    uint256 private constant MAXIMUM_CONTRIBUTION = 250e6; // 250 USDC

    /*//////////////////////////////////////////////////////////////
                            EVENTS & ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnNewDAO(bool indexed referralDiscount, uint256 launchDate);
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
    event OnCouponRedeemed(address indexed member, uint256 indexed couponAmount);
    event OnParentRewarded(
        address indexed parent,
        uint256 indexed layer,
        address indexed child,
        uint256 reward
    );
    event OnParentRewardTransferFailed(
        address indexed parent,
        uint256 indexed layer,
        address indexed child,
        uint256 reward
    );
    event OnMemberKYCVerified(address indexed member);
    event OnBenefitMultiplierConsumerChanged(
        address indexed newBenefitMultiplierConsumer,
        address indexed oldBenefitMultiplierConsumer
    );
    event OnRefund(address indexed member, uint256 indexed amount);
    event OnNewOperator(address indexed oldOperator, address indexed newOperator);
    event OnNewCouponPoolAddress(address indexed oldCouponPool, address indexed newCouponPool);
    event OnNewCCIPReceiverContract(
        address indexed oldCCIPReceiverContract,
        address indexed newCCIPReceiverContract
    );

    error PrejoinModule__ZeroAddress();
    error PrejoinModule__InvalidLaunchDate();
    error PrejoinModule__DAOAlreadyLaunched();
    error PrejoinModule__ZeroAmount();
    error PrejoinModule__ContributionOutOfRange();
    error PrejoinModule__ParentMustKYCFirst();
    error PrejoinModule__AlreadyMember();
    error PrejoinModule__MemberAlreadyKYCed();
    error PrejoinModule__HasNotPaid();
    error PrejoinModule__NotKYCed();
    error PrejoinModule__tDAONotReadyYet();
    error PrejoinModule__NotEnoughFunds(uint256 amountToRefund, uint256 neededAmount);
    error PrejoinModule__NotAuthorizedCaller();
    error PrejoinModule__WrongModuleState();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _operator,
        address _KYCProvider,
        address _usdcAddress,
        address _benefitMultiplierConsumer
    ) external initializer {
        AddressAndStates._notZeroAddress(_operator);
        AddressAndStates._notZeroAddress(_KYCProvider);
        AddressAndStates._notZeroAddress(_usdcAddress);
        AddressAndStates._notZeroAddress(_benefitMultiplierConsumer);
        _initDependencies();

        _grantRoles(_operator, _KYCProvider);

        operator = _operator;
        usdc = IERC20(_usdcAddress);
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

    /*//////////////////////////////////////////////////////////////
                               DAO ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create a new DAO
     * @param isReferralDiscountEnabled The referral discount status of the DAO
     * @param launchDate An estimated launch date of the DAO
     * @dev The launch date must be in seconds
     * @dev The objective amount must be in USDC, six decimals
     * @dev The objective amount can be 0, if the DAO is already launched or the objective amount is not defined
     */
    function createDAO(
        bool isReferralDiscountEnabled,
        uint256 launchDate,
        address _bmConsumer
    ) external onlyRole(ModuleConstants.OPERATOR) {
        require(launchDate > block.timestamp, PrejoinModule__InvalidLaunchDate());

        // Create the new DAO
        nameToDAOData[DAO_NAME].name = DAO_NAME;
        nameToDAOData[DAO_NAME].preJoinEnabled = true;
        nameToDAOData[DAO_NAME].referralDiscount = isReferralDiscountEnabled;
        nameToDAOData[DAO_NAME].DAOAdmin = operator;
        nameToDAOData[DAO_NAME].launchDate = launchDate;
        nameToDAOData[DAO_NAME].bmConsumer = IBenefitMultiplierConsumer(_bmConsumer);

        emit OnNewDAO(isReferralDiscountEnabled, launchDate);
    }

    /**
     * @notice Update the DAO estimated launch date
     */
    function updateLaunchDate(uint256 launchDate) external onlyRole(ModuleConstants.OPERATOR) {
        require(
            launchDate > nameToDAOData[DAO_NAME].launchDate,
            PrejoinModule__InvalidLaunchDate()
        );
        require(
            nameToDAOData[DAO_NAME].DAOAddress == address(0),
            PrejoinModule__DAOAlreadyLaunched()
        );
        nameToDAOData[DAO_NAME].launchDate = launchDate;

        emit OnDAOLaunchDateUpdated(launchDate);
    }

    /**
     * @notice Method to be called after a tDAO is deployed
     * @param tDAOAddress The address of the tDAO
     * @param isReferralDiscountEnabled The referral discount status of the DAO
     * @dev Only callable from the OPERATOR
     * @dev The tDAOAddress must be different from 0
     * @dev It will disable the preJoinEnabled status of the DAO
     */
    function launchDAO(
        address tDAOAddress,
        address entryModuleAddress,
        bool isReferralDiscountEnabled
    ) external onlyRole(ModuleConstants.OPERATOR) {
        AddressAndStates._onlyModuleState(moduleState, ModuleState.Enabled);
        AddressAndStates._notZeroAddress(tDAOAddress);
        AddressAndStates._notZeroAddress(entryModuleAddress);
        require(
            nameToDAOData[DAO_NAME].DAOAddress == address(0),
            PrejoinModule__DAOAlreadyLaunched()
        );

        nameToDAOData[DAO_NAME].preJoinEnabled = false;
        nameToDAOData[DAO_NAME].referralDiscount = isReferralDiscountEnabled;
        nameToDAOData[DAO_NAME].DAOAddress = tDAOAddress;
        nameToDAOData[DAO_NAME].entryModule = entryModuleAddress;
        nameToDAOData[DAO_NAME].launchDate = block.timestamp;

        Reserve memory reserve = _getReservesValuesHook(ITakasureReserve(tDAOAddress));

        reserve.referralDiscount = isReferralDiscountEnabled;

        _setReservesValuesHook(ITakasureReserve(tDAOAddress), reserve);

        emit OnDAOLaunched(tDAOAddress);

        // At last we disable the module, this way the payments will be stopped
        moduleState = ModuleState.Disabled;
    }

    /**
     * @notice Switch the referralDiscount status of a DAO
     */
    function switchReferralDiscount() external onlyRole(ModuleConstants.OPERATOR) {
        nameToDAOData[DAO_NAME].referralDiscount = !nameToDAOData[DAO_NAME].referralDiscount;

        emit OnReferralDiscountSwitched(nameToDAOData[DAO_NAME].referralDiscount);
    }

    /**
     * @notice Assign a rePool address to a tDAO name
     * @param rePoolAddress The address of the rePool
     */
    function enableRepool(address rePoolAddress) external onlyRole(ModuleConstants.OPERATOR) {
        AddressAndStates._notZeroAddress(rePoolAddress);
        require(nameToDAOData[DAO_NAME].DAOAddress != address(0), PrejoinModule__tDAONotReadyYet());
        nameToDAOData[DAO_NAME].rePoolAddress = rePoolAddress;

        emit OnRepoolEnabled(rePoolAddress);
    }

    function transferToRepool() external onlyRole(ModuleConstants.OPERATOR) {
        require(moduleState != ModuleState.Deprecated, PrejoinModule__WrongModuleState());
        require(nameToDAOData[DAO_NAME].rePoolAddress != address(0), PrejoinModule__ZeroAddress());
        require(nameToDAOData[DAO_NAME].toRepool > 0, PrejoinModule__ZeroAmount());

        uint256 amount = nameToDAOData[DAO_NAME].toRepool;
        address rePoolAddress = nameToDAOData[DAO_NAME].rePoolAddress;

        nameToDAOData[DAO_NAME].toRepool = 0;

        usdc.safeTransfer(rePoolAddress, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 JOINS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pay a contribution to a DAO
     * @param contribution The amount of the contribution. In USDC six decimals
     * @param parent The address of the parent. Optional
     * @dev The contribution must be between MINIMUM_CONTRIBUTION and MAXIMUM_CONTRIBUTION
     * @dev The function will create a prepaid member object with the contribution data if
     *      the DAO is not deployed yet, otherwise it will call the DAO to join
     * @dev It will apply the discounts and rewards if the DAO has the features enabled
     */
    function payContribution(
        uint256 contribution,
        address parent
    ) external returns (uint256 finalFee, uint256 discount) {
        (finalFee, discount) = _payContribution(contribution, parent, msg.sender, 0);
    }

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
        uint256 couponAmount
    ) external returns (uint256 finalFee, uint256 discount) {
        _onlyCouponRedeemerOrCcipReceiver();

        (finalFee, discount) = _payContribution(contribution, parent, newMember, couponAmount);

        if (couponAmount > 0) {
            isMemberCouponRedeemer[newMember] = true;
            emit OnCouponRedeemed(newMember, couponAmount);
        }
    }

    /**
     * @notice Set the KYC status of a member
     * @param user The address of the member
     * @dev Only the KYC_PROVIDER can set the KYC status
     */
    function approveKYC(address user) external onlyRole(ModuleConstants.KYC_PROVIDER) {
        // It will be possible to KYC a member that was left behind in the process
        // This will allow them to join the DAO
        require(
            moduleState == ModuleState.Enabled || moduleState == ModuleState.Disabled,
            PrejoinModule__WrongModuleState()
        );
        AddressAndStates._notZeroAddress(user);
        // Initial checks
        // Can not KYC a member that is already KYCed
        require(!isMemberKYCed[user], PrejoinModule__MemberAlreadyKYCed());

        // The member must have already pre-paid
        require(
            nameToDAOData[DAO_NAME].prepaidMembers[user].contributionBeforeFee != 0,
            PrejoinModule__HasNotPaid()
        );

        // Update the KYC status
        isMemberKYCed[user] = true;

        address parent = childToParent[user];

        for (uint256 i; i < uint256(MAX_TIER); ++i) {
            if (parent == address(0)) break;

            uint256 layer = i + 1;

            uint256 parentReward = nameToDAOData[DAO_NAME]
                .prepaidMembers[parent]
                .parentRewardsByChild[user];

            // Reset the rewards for this child
            nameToDAOData[DAO_NAME].prepaidMembers[parent].parentRewardsByChild[user] = 0;

            try usdc.transfer(parent, parentReward) {
                // Emit the event only if the transfer was successful
                emit OnParentRewarded(parent, layer, user, parentReward);
            } catch {
                // If the transfer failed, we need to revert the rewards
                nameToDAOData[DAO_NAME].prepaidMembers[parent].parentRewardsByChild[
                    user
                ] = parentReward;

                // Emit an event for off-chain monitoring
                emit OnParentRewardTransferFailed(parent, layer, user, parentReward);
            }

            // We update the parent address to check the next parent
            parent = childToParent[parent];
        }

        emit OnMemberKYCVerified(user);
    }

    /**
     * @notice Join a tDAO
     * @param newMember The address of the new member
     * @dev The member must be KYCed
     * @dev The member must have a parent
     * @dev The member must have a tDAO assigned
     */
    function joinDAO(address newMember) external nonReentrant {
        AddressAndStates._onlyModuleState(moduleState, ModuleState.Disabled);
        // Initial checks
        require(isMemberKYCed[newMember], PrejoinModule__NotKYCed());

        require(
            nameToDAOData[DAO_NAME].DAOAddress != address(0) &&
                !nameToDAOData[DAO_NAME].preJoinEnabled,
            PrejoinModule__tDAONotReadyYet()
        );

        // Finally, we join the prepaidMember to the tDAO
        IEntryModule(nameToDAOData[DAO_NAME].entryModule).joinPool(
            newMember,
            childToParent[newMember],
            nameToDAOData[DAO_NAME].prepaidMembers[newMember].contributionBeforeFee,
            ModuleConstants.DEFAULT_MEMBERSHIP_DURATION
        );

        usdc.safeTransfer(
            nameToDAOData[DAO_NAME].DAOAddress,
            nameToDAOData[DAO_NAME].prepaidMembers[newMember].contributionAfterFee
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
            member == msg.sender || hasRole(ModuleConstants.OPERATOR, msg.sender),
            PrejoinModule__NotAuthorizedCaller()
        );
        require(
            nameToDAOData[DAO_NAME].launchDate < block.timestamp &&
                nameToDAOData[DAO_NAME].DAOAddress == address(0),
            PrejoinModule__tDAONotReadyYet()
        );

        _refund(member);
    }

    /**
     * @notice Admin can refund a prepaid member
     * @param member The address of the member
     * @dev Intended to be called by the OPERATOR in spetial cases
     */
    function refundByAdmin(address member) external onlyRole(ModuleConstants.OPERATOR) {
        _refund(member);
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    function setNewBenefitMultiplierConsumer(
        address newBenefitMultiplierConsumer
    ) external onlyRole(ModuleConstants.OPERATOR) {
        AddressAndStates._notZeroAddress(newBenefitMultiplierConsumer);
        address oldBenefitMultiplierConsumer = address(nameToDAOData[DAO_NAME].bmConsumer);
        nameToDAOData[DAO_NAME].bmConsumer = IBenefitMultiplierConsumer(
            newBenefitMultiplierConsumer
        );

        emit OnBenefitMultiplierConsumerChanged(
            newBenefitMultiplierConsumer,
            oldBenefitMultiplierConsumer
        );
    }

    function setNewOperator(address newOperator) external onlyRole(ModuleConstants.OPERATOR) {
        AddressAndStates._notZeroAddress(newOperator);
        address oldOperator = operator;

        // Setting the new operator address
        operator = newOperator;

        // Fixing the roles
        _grantRole(ModuleConstants.OPERATOR, newOperator);
        _revokeRole(ModuleConstants.OPERATOR, msg.sender);

        usdc.safeTransferFrom(oldOperator, newOperator, usdc.balanceOf(oldOperator));

        emit OnNewOperator(oldOperator, newOperator);
    }

    function setCouponPoolAddress(address _couponPool) external onlyRole(ModuleConstants.OPERATOR) {
        AddressAndStates._notZeroAddress(_couponPool);
        address oldCouponPool = couponPool;
        couponPool = _couponPool;
        emit OnNewCouponPoolAddress(oldCouponPool, _couponPool);
    }

    function setCCIPReceiverContract(
        address _ccipReceiverContract
    ) external onlyRole(ModuleConstants.OPERATOR) {
        AddressAndStates._notZeroAddress(_ccipReceiverContract);
        address oldCCIPReceiverContract = ccipReceiverContract;
        ccipReceiverContract = _ccipReceiverContract;
        emit OnNewCCIPReceiverContract(oldCCIPReceiverContract, _ccipReceiverContract);
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
        contributionBeforeFee = nameToDAOData[DAO_NAME]
            .prepaidMembers[member]
            .contributionBeforeFee;
        contributionAfterFee = nameToDAOData[DAO_NAME].prepaidMembers[member].contributionAfterFee;
        feeToOperator = nameToDAOData[DAO_NAME].prepaidMembers[member].feeToOperator;
        discount = nameToDAOData[DAO_NAME].prepaidMembers[member].discount;
    }

    function getParentRewardsByChild(
        address parent,
        address child
    ) external view returns (uint256 rewards) {
        rewards = nameToDAOData[DAO_NAME].prepaidMembers[parent].parentRewardsByChild[child];
    }

    function getParentRewardsByLayer(
        address parent,
        uint256 layer
    ) external view returns (uint256 rewards) {
        rewards = nameToDAOData[DAO_NAME].prepaidMembers[parent].parentRewardsByLayer[layer];
    }

    function getDAOData()
        external
        view
        returns (
            bool preJoinEnabled,
            bool referralDiscount,
            address DAOAddress,
            uint256 launchDate,
            uint256 currentAmount,
            uint256 collectedFees,
            address rePoolAddress,
            uint256 toRepool,
            uint256 referralReserve
        )
    {
        preJoinEnabled = nameToDAOData[DAO_NAME].preJoinEnabled;
        referralDiscount = nameToDAOData[DAO_NAME].referralDiscount;
        DAOAddress = nameToDAOData[DAO_NAME].DAOAddress;
        launchDate = nameToDAOData[DAO_NAME].launchDate;
        currentAmount = nameToDAOData[DAO_NAME].currentAmount;
        collectedFees = nameToDAOData[DAO_NAME].collectedFees;
        rePoolAddress = nameToDAOData[DAO_NAME].rePoolAddress;
        toRepool = nameToDAOData[DAO_NAME].toRepool;
        referralReserve = nameToDAOData[DAO_NAME].referralReserve;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _initDependencies() internal {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuardTransient_init();
    }

    function _grantRoles(address _operator, address _KYCProvider) internal {
        _grantRole(DEFAULT_ADMIN_ROLE, _operator);
        _grantRole(ModuleConstants.OPERATOR, _operator);
        _grantRole(ModuleConstants.KYC_PROVIDER, _KYCProvider);
    }

    function _getBenefitMultiplierFromOracle(address _member) internal {
        string memory memberAddressToString = Strings.toHexString(uint256(uint160(_member)), 20);
        string[] memory args = new string[](1);
        args[0] = memberAddressToString;
        nameToDAOData[DAO_NAME].bmConsumer.sendRequest(args);
    }

    function _payContribution(
        uint256 _contribution,
        address _parent,
        address _newMember,
        uint256 _couponAmount
    ) internal nonReentrant returns (uint256 _finalFee, uint256 _discount) {
        AddressAndStates._onlyModuleState(moduleState, ModuleState.Enabled);

        uint256 normalizedContribution = (_contribution /
            ModuleConstants.DECIMAL_REQUIREMENT_PRECISION_USDC) *
            ModuleConstants.DECIMAL_REQUIREMENT_PRECISION_USDC;

        // The prepaid member object is created
        uint256 realContribution;

        if (_couponAmount > normalizedContribution) realContribution = _couponAmount;
        else realContribution = normalizedContribution;

        _payContributionChecks(realContribution, _parent, _newMember);

        _finalFee = (realContribution * SERVICE_FEE_RATIO) / 100;

        // It will get a discount as a pre-joiner
        _discount +=
            ((realContribution - _couponAmount) * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100;
        uint256 toReferralReserve;

        if (nameToDAOData[DAO_NAME].referralDiscount) {
            toReferralReserve = (realContribution * ModuleConstants.REFERRAL_RESERVE) / 100;

            if (_parent != address(0)) {
                uint256 referralDiscount = ((realContribution - _couponAmount) *
                    ModuleConstants.REFERRAL_DISCOUNT_RATIO) / 100;
                _discount += referralDiscount;

                childToParent[_newMember] = _parent;

                (_finalFee, nameToDAOData[DAO_NAME].referralReserve) = _parentRewards({
                    _initialChildToCheck: _newMember,
                    _contribution: realContribution,
                    _currentReferralReserve: nameToDAOData[DAO_NAME].referralReserve,
                    _toReferralReserve: toReferralReserve,
                    _currentFee: _finalFee
                });
            } else {
                nameToDAOData[DAO_NAME].referralReserve += toReferralReserve;
            }
        }

        uint256 rePoolFee = (realContribution * REPOOL_FEE_RATIO) / 100;

        _finalFee -= _discount + toReferralReserve + rePoolFee;

        assert(
            (realContribution * SERVICE_FEE_RATIO) / 100 ==
                _finalFee + _discount + toReferralReserve + rePoolFee
        );

        nameToDAOData[DAO_NAME].toRepool += rePoolFee;
        nameToDAOData[DAO_NAME].currentAmount +=
            realContribution -
            (realContribution * SERVICE_FEE_RATIO) /
            100;
        nameToDAOData[DAO_NAME].collectedFees += _finalFee;

        uint256 amountToTransfer = realContribution - _discount - _couponAmount;

        if (amountToTransfer > 0) {
            if (msg.sender == ccipReceiverContract) {
                usdc.safeTransferFrom(ccipReceiverContract, address(this), amountToTransfer);

                // Note: This is a temporary solution to test the CCIP integration in the testnet
                // This is because in testnet we are using a different USDC contract for easier testing
                // IERC20(0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d).safeTransferFrom(
                //     ccipReceiverContract,
                //     address(this),
                //     amountToTransfer
                // );
            } else {
                usdc.safeTransferFrom(_newMember, address(this), amountToTransfer);
            }
        }

        if (_couponAmount > 0) {
            usdc.safeTransferFrom(couponPool, address(this), _couponAmount);
        }

        usdc.safeTransfer(operator, _finalFee);

        nameToDAOData[DAO_NAME].prepaidMembers[_newMember].member = _newMember;
        nameToDAOData[DAO_NAME].prepaidMembers[_newMember].contributionBeforeFee = realContribution;
        nameToDAOData[DAO_NAME].prepaidMembers[_newMember].contributionAfterFee =
            realContribution -
            (realContribution * SERVICE_FEE_RATIO) /
            100;
        nameToDAOData[DAO_NAME].prepaidMembers[_newMember].feeToOperator = _finalFee;
        nameToDAOData[DAO_NAME].prepaidMembers[_newMember].discount = _discount;

        // Finally, we request the benefit multiplier for the member, this to have it ready when the member joins the DAO
        _getBenefitMultiplierFromOracle(_newMember);

        emit OnPrepayment(_parent, _newMember, realContribution, _finalFee, _discount);
    }

    function _payContributionChecks(
        uint256 _contribution,
        address _parent,
        address _newMember
    ) internal view {
        // DAO must exist

        require(
            nameToDAOData[DAO_NAME].preJoinEnabled ||
                nameToDAOData[DAO_NAME].DAOAddress != address(0),
            PrejoinModule__tDAONotReadyYet()
        );

        // We check if the member already exists
        require(
            nameToDAOData[DAO_NAME].prepaidMembers[_newMember].contributionBeforeFee == 0,
            PrejoinModule__AlreadyMember()
        );

        require(
            _contribution >= MINIMUM_CONTRIBUTION && _contribution <= MAXIMUM_CONTRIBUTION,
            PrejoinModule__ContributionOutOfRange()
        );

        if (_parent != address(0))
            require(isMemberKYCed[_parent], PrejoinModule__ParentMustKYCFirst());
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

            nameToDAOData[DAO_NAME]
                .prepaidMembers[childToParent[currentChildToCheck]]
                .parentRewardsByChild[_initialChildToCheck] =
                (_contribution * _referralRewardRatioByLayer(i + 1)) /
                (100 * DECIMAL_CORRECTION);

            nameToDAOData[DAO_NAME]
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

    function _refund(address _member) internal {
        require(
            moduleState == ModuleState.Enabled || moduleState == ModuleState.Disabled,
            PrejoinModule__WrongModuleState()
        );
        require(
            nameToDAOData[DAO_NAME].prepaidMembers[_member].contributionBeforeFee != 0,
            PrejoinModule__HasNotPaid()
        );

        uint256 discountReceived = nameToDAOData[DAO_NAME].prepaidMembers[_member].discount;

        uint256 amountToRefund = nameToDAOData[DAO_NAME]
            .prepaidMembers[_member]
            .contributionBeforeFee - discountReceived;

        require(
            amountToRefund <= usdc.balanceOf(address(this)),
            PrejoinModule__NotEnoughFunds(amountToRefund, usdc.balanceOf(address(this)))
        );

        uint256 leftover = amountToRefund;

        // We deduct first from the tDAO currentAmount only the part the member contributed
        nameToDAOData[DAO_NAME].currentAmount -= nameToDAOData[DAO_NAME]
            .prepaidMembers[_member]
            .contributionAfterFee;

        // We update the leftover amount
        leftover -= nameToDAOData[DAO_NAME].prepaidMembers[_member].contributionAfterFee;

        // We compare now against the referralReserve
        if (leftover <= nameToDAOData[DAO_NAME].referralReserve) {
            // If it is enough we deduct the leftover from the referralReserve
            nameToDAOData[DAO_NAME].referralReserve -= leftover;
        } else {
            // We update the leftover value and set the referralReserve to 0
            leftover -= nameToDAOData[DAO_NAME].referralReserve;
            nameToDAOData[DAO_NAME].referralReserve = 0;

            // We compare now against the repool amount
            if (leftover <= nameToDAOData[DAO_NAME].toRepool) {
                nameToDAOData[DAO_NAME].toRepool -= leftover;
            } else {
                nameToDAOData[DAO_NAME].toRepool = 0;
            }
        }

        delete nameToDAOData[DAO_NAME].prepaidMembers[_member];

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

    function _onlyCouponRedeemerOrCcipReceiver() internal view {
        require(
            hasRole(ModuleConstants.COUPON_REDEEMER, msg.sender) ||
                msg.sender == ccipReceiverContract,
            PrejoinModule__NotAuthorizedCaller()
        );
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(ModuleConstants.OPERATOR) {}
}
