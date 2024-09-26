// SPDX-License-Identifier: GPL-3.0

/**
 * @title ReferralGateway
 * @author Maikel Ordaz
 * @dev This contract will manage all the functionalities related to the referral system and pre-joins
 *      to the LifeDao protocol
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITakasurePool} from "contracts/interfaces/ITakasurePool.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Member, MemberState} from "contracts/types/TakasureTypes.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.25;

contract ReferralGateway is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 private usdc;

    uint8 public constant SERVICE_FEE = 20;
    uint256 private constant MINIMUM_SERVICE_FEE = 25e6; // 25 USDC
    uint256 private constant MAXIMUM_SERVICE_FEE = 250e6; // 250 USDC
    uint256 private constant MAX_TIER = 4;
    uint8 public cocRewardRatio;
    uint8 public ambassadorRewardRatio;

    uint256 public collectedFees;
    address private takadaoOperator;

    bytes32 private constant TAKADAO_OPERATOR = keccak256("TAKADAO_OPERATOR");
    bytes32 public constant KYC_PROVIDER = keccak256("KYC_PROVIDER");
    bytes32 private constant AMBASSADOR = keccak256("AMBASSADOR");
    bytes32 private constant COC = keccak256("COC");

    mapping(address parent => mapping(address child => uint256 rewards)) public parentRewards;
    mapping(uint256 childCounter => address child) public childs;
    mapping(address child => PrePaidMember) public prePaidMembers;
    mapping(string tDaoName => Dao daoData) private daoDatas;
    mapping(address child => bool) public isChildKYCed;

    struct PrePaidMember {
        string tDaoName;
        address child;
        address parent;
        uint256 contributionBeforeFee;
        uint256 contributionAfterFee;
    }

    struct Dao {
        string name;
        bool isPreJoinEnabled;
        address prePaymentAdmin; // The one that can modify the dao settings
        address daoAddress; // To be assigned when the tDAO is deployed
        uint256 launchDate; // in seconds
        uint256 objectiveAmount; // in USDC, six decimals
        uint256 currentAmount; // in USDC, six decimals
    }

    uint256 public childCounter;

    event OnPreJoinEnabledChanged(bool indexed isPreJoinEnabled);
    event OnNewAmbassadorProposal(address indexed proposedAmbassador);
    event OnNewAmbassador(address indexed ambassador);
    event OnPrePayment(address indexed parent, address indexed child, uint256 indexed contribution);
    event OnParentRewarded(address indexed parent, address indexed child, uint256 indexed reward);
    event OnChildKycVerified(address indexed child);

    error ReferralGateway__ZeroAddress();
    error ReferralGateway__ContributionOutOfRange();
    error ReferralGateway__MemberAlreadyKYCed();
    error ReferralGateway__NotAllowedToPrePay();
    error ReferralGateway__NotKYCed();
    error ReferralGateway__tDAOAddressNotAssignedYet();
    error ReferralGateway__OnlyDaoAdmin();

    modifier notZeroAddress(address _address) {
        if (_address == address(0)) {
            revert ReferralGateway__ZeroAddress();
        }
        _;
    }

    modifier onlyDaoAdmin(string calldata tDaoName) {
        if (daoDatas[tDaoName].prePaymentAdmin != msg.sender) {
            revert ReferralGateway__OnlyDaoAdmin();
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _takadaoOperator,
        address _kycProvider,
        address _usdcAddress
    ) external notZeroAddress(_takadaoOperator) notZeroAddress(_usdcAddress) initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _takadaoOperator);
        _grantRole(TAKADAO_OPERATOR, _takadaoOperator);
        _grantRole(KYC_PROVIDER, _kycProvider);

        takadaoOperator = _takadaoOperator;
        // isPreJoinEnabled = true;
        usdc = IERC20(_usdcAddress);

        cocRewardRatio = 30;
        ambassadorRewardRatio = 20;
    }

    /**
     * @notice Create a new Dao
     * @param daoName The name of the Dao
     * @param _isPreJoinEnabled The pre-join status of the Dao
     * @param launchDate The launch date of the Dao
     * @param objectiveAmount The objective amount of the Dao
     * @dev The launch date must be in seconds
     * @dev The launch date can be 0, if the Dao is already launched or the launch date is not defined
     * @dev The objective amount must be in USDC, six decimals
     * @dev The objective amount can be 0, if the Dao is already launched or the objective amount is not defined
     */
    function createDao(
        string calldata daoName,
        bool _isPreJoinEnabled,
        uint256 launchDate,
        uint256 objectiveAmount
    ) external {
        // Create the new Dao
        Dao memory dao = Dao({
            name: daoName, // To be used as a key
            isPreJoinEnabled: _isPreJoinEnabled,
            prePaymentAdmin: msg.sender,
            daoAddress: address(0), // To be assigned when the tDAO is deployed
            launchDate: launchDate, // in seconds
            objectiveAmount: objectiveAmount,
            currentAmount: 0
        });

        // Update the necessary mappings
        daoDatas[dao.name] = dao;
    }

    /**
     * @notice Register an ambassador
     * @param ambassador The address to register as ambassador
     * @dev Only the TAKADAO_OPERATOR can register an ambassador
     */
    function registerAmbassador(
        address ambassador
    ) external notZeroAddress(ambassador) onlyRole(TAKADAO_OPERATOR) {
        _grantRole(AMBASSADOR, ambassador);

        emit OnNewAmbassador(ambassador);
    }

    /**
     * @notice Register a COC
     * @param coc The address to register as coc
     * @dev Only the TAKADAO_OPERATOR can register an COC
     */
    function registerCOC(address coc) external notZeroAddress(coc) onlyRole(TAKADAO_OPERATOR) {
        _grantRole(COC, coc);

        emit OnNewAmbassador(coc);
    }

    /**
     * @notice Assign a tDAO address to a tDAO name
     * @param tDaoName The name of the tDAO
     */
    function assignTDaoAddress(
        string calldata tDaoName,
        address tDaoAddress
    ) external notZeroAddress(tDaoAddress) onlyDaoAdmin(tDaoName) {
        daoDatas[tDaoName].daoAddress = tDaoAddress;
    }

    /**
     * @notice Pre pay for a membership
     * @param parent The address of the parent
     * @param contribution The amount to pay
     * @param tDaoName The name of the tDAO
     * @dev The parent address is optional
     * @dev The contribution must be between 25 and 250 USDC
     * @dev The parent reward ratio depends on the parent role
     */
    function prePayment(address parent, uint256 contribution, string calldata tDaoName) external {
        Dao memory dao = daoDatas[tDaoName];
        // Initial checks
        if (!dao.isPreJoinEnabled) {
            revert ReferralGateway__NotAllowedToPrePay();
        }

        if (contribution < MINIMUM_SERVICE_FEE || contribution > MAXIMUM_SERVICE_FEE) {
            revert ReferralGateway__ContributionOutOfRange();
        }

        // Calculate the fee and create the new pre-paid member
        uint256 fee = (contribution * SERVICE_FEE) / 100;
        uint256 paymentCollectedFees = fee;

        ++childCounter;

        PrePaidMember memory prePaidMember = PrePaidMember({
            tDaoName: tDaoName,
            child: msg.sender,
            parent: parent,
            contributionBeforeFee: contribution,
            contributionAfterFee: contribution - fee
        });

        // Update the necessary mappings
        childs[childCounter] = msg.sender;
        prePaidMembers[msg.sender] = prePaidMember;

        // Transfer the contribution to the contract
        usdc.safeTransferFrom(msg.sender, address(this), contribution);

        // As the parent is optional, we need to check if it is not zero
        if (parent != address(0)) {
            // First we need to check the correct reward ratio for the parent, based on the parent role
            uint256 rewardRatio;
            if (hasRole(AMBASSADOR, parent)) {
                rewardRatio = ambassadorRewardRatio;
            } else if (hasRole(COC, parent)) {
                rewardRatio = cocRewardRatio;
            }

            // Calculate the parent reward, the collected fees
            uint256 parentReward = (fee * rewardRatio) / 100;
            paymentCollectedFees -= parentReward;

            // We check if the parent is child of another parent up to 4 tiers back
            address currentParentToCheck = parent;
            for (uint8 i = 1; i <= MAX_TIER; ++i) {
                if (prePaidMembers[currentParentToCheck].parent != address(0)) {
                    // We calculate the grandParent reward
                    address grandParent = prePaidMembers[currentParentToCheck].parent;
                    uint256 grandParentReward = ((rewardRatio ** (i)) * parentReward) /
                        (100 ** (i));

                    // Update the parentRewards mapping and transfer the reward
                    parentRewards[grandParent][currentParentToCheck] = 0;
                    usdc.safeTransfer(grandParent, grandParentReward);
                    emit OnParentRewarded(grandParent, msg.sender, grandParentReward);

                    // Lastly, we update the currentParentToCheck variable and the paymentCollectedFees
                    currentParentToCheck = grandParent;
                    paymentCollectedFees -= grandParentReward;
                } else {
                    break;
                }
            }

            // If the child is already KYCed, we can transfer the parent reward
            if (isChildKYCed[msg.sender]) {
                parentRewards[parent][msg.sender] = 0;
                usdc.safeTransfer(parent, parentReward);

                emit OnParentRewarded(parent, msg.sender, parentReward);
            } else {
                // Otherwise, we store the parent reward in the parentRewards mapping
                parentRewards[parent][msg.sender] = parentReward;
            }
        }

        collectedFees += paymentCollectedFees;
        emit OnPrePayment(parent, msg.sender, contribution);
    }

    /**
     * @notice Join a tDAO
     * @dev The member must be KYCed
     * @dev The member must have a parent
     * @dev The member must have a tDAO assigned
     */
    function joinDao() external {
        // Initial checks
        PrePaidMember memory member = prePaidMembers[msg.sender];
        Dao memory dao = daoDatas[member.tDaoName];

        if (dao.daoAddress == address(0)) {
            revert ReferralGateway__tDAOAddressNotAssignedYet();
        }
        if (!isChildKYCed[member.child]) {
            revert ReferralGateway__NotKYCed();
        }
        if (!dao.isPreJoinEnabled) {
            revert ReferralGateway__NotAllowedToPrePay();
        }

        // If the member has a parent, we need to check if the parent has a reward
        address parent = member.parent;

        if (parent != address(0)) {
            uint256 parentReward = parentRewards[parent][msg.sender];

            if (parentReward > 0) {
                parentRewards[parent][msg.sender] = 0;
                usdc.safeTransfer(parent, parentReward);

                emit OnParentRewarded(parent, msg.sender, parentReward);
            }
        }

        // Finally, we join the member to the tDAO
        ITakasurePool(dao.daoAddress).joinByReferral(
            msg.sender,
            member.contributionBeforeFee,
            member.contributionAfterFee
        );

        usdc.safeTransfer(dao.daoAddress, member.contributionAfterFee);
    }

    /**
     * @notice Set the KYC status of a member
     * @param child The address of the member
     * @dev Only the KYC_PROVIDER can set the KYC status
     */
    function setKYCStatus(address child) external notZeroAddress(child) onlyRole(KYC_PROVIDER) {
        // Initial checks
        PrePaidMember memory member = prePaidMembers[child];
        if (isChildKYCed[child]) {
            revert ReferralGateway__MemberAlreadyKYCed();
        }

        // Update the KYC status
        isChildKYCed[child] = true;

        // If the member has a parent, we need to check if the parent has a reward
        if (member.contributionBeforeFee > 0 && member.parent != address(0)) {
            address parent = member.parent;
            uint256 parentReward = parentRewards[parent][child];
            parentRewards[parent][child] = 0;

            usdc.safeTransfer(parent, parentReward);

            emit OnParentRewarded(parent, child, parentReward);
        }

        emit OnChildKycVerified(child);
    }

    function setPreJoinEnabled(
        string calldata tDaoName,
        bool _isPreJoinEnabled
    ) external onlyDaoAdmin(tDaoName) {
        daoDatas[tDaoName].isPreJoinEnabled = _isPreJoinEnabled;
        emit OnPreJoinEnabledChanged(_isPreJoinEnabled);
    }

    function setNewCocRewardRatio(uint8 _newCocRewardRatio) external onlyRole(TAKADAO_OPERATOR) {
        cocRewardRatio = _newCocRewardRatio;
    }

    function setNewAmbassadorRewardRatio(
        uint8 _newAmbassadorRewardRatio
    ) external onlyRole(TAKADAO_OPERATOR) {
        ambassadorRewardRatio = _newAmbassadorRewardRatio;
    }

    function withdrawFees() external onlyRole(TAKADAO_OPERATOR) {
        uint256 _collectedFees = collectedFees;
        collectedFees = 0;
        usdc.safeTransfer(takadaoOperator, _collectedFees);
    }

    function getDaoData(string calldata tDaoName) external view returns (Dao memory) {
        return daoDatas[tDaoName];
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(TAKADAO_OPERATOR) {}
}
