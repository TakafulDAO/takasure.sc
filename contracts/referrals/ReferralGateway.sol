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
    uint256 public constant CONTRIBUTION_DISCOUNT = 5;
    uint256 private constant MINIMUM_SERVICE_FEE = 25e6; // 25 USDC
    uint256 private constant MAXIMUM_SERVICE_FEE = 250e6; // 250 USDC
    // For the ambassadors reward ratio
    uint256 private constant MAX_TIER = 4;
    int256 private constant A = -3_125;
    int256 private constant B = 30_500;
    int256 private constant C = -99_625;
    int256 private constant D = 112_250;
    uint256 private constant DECIMAL_CORRECTION = 10_000;

    uint256 public collectedFees;
    address private takadaoOperator;

    bytes32 private constant TAKADAO_OPERATOR = keccak256("TAKADAO_OPERATOR");
    bytes32 public constant KYC_PROVIDER = keccak256("KYC_PROVIDER");
    bytes32 private constant AMBASSADOR = keccak256("AMBASSADOR");
    bytes32 private constant COC = keccak256("COC");

    mapping(address parent => mapping(address child => uint256 rewards))
        public parentRewardsByChild;
    mapping(address parent => mapping(uint256 layer => uint256 rewards))
        public parentRewardsByLayer;
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
        uint256 amountToCompensate; // in USDC, six decimals
    }

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
            currentAmount: 0,
            amountToCompensate: 0
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
     * @notice Register a CoC
     * @param CoC The address to register as coc
     * @dev Only the TAKADAO_OPERATOR can register an COC
     */
    function registerCoC(address CoC) external notZeroAddress(CoC) onlyRole(TAKADAO_OPERATOR) {
        _grantRole(COC, CoC);

        emit OnNewAmbassador(CoC);
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
        uint256 contributionAfterDiscount = (contribution * (100 - CONTRIBUTION_DISCOUNT)) / 100;
        uint256 fee = (contribution * SERVICE_FEE) / 100;
        uint256 paymentCollectedFees = fee;

        PrePaidMember memory prePaidMember = PrePaidMember({
            tDaoName: tDaoName,
            child: msg.sender,
            parent: parent,
            contributionBeforeFee: contribution,
            contributionAfterFee: contribution - fee
        });

        // Update the necessary mappings and values
        prePaidMembers[msg.sender] = prePaidMember;

        // Transfer the contribution to the contract
        usdc.safeTransferFrom(msg.sender, address(this), contributionAfterDiscount);

        // As the parent is optional, we need to check if it is not zero
        if (parent != address(0)) {
            address currentChildToCheck = msg.sender;
            // We loop through the parent chain up to 4 tiers back
            for (uint256 i; i < MAX_TIER; ++i) {
                // We need to check child by child if it has a parent
                if (prePaidMembers[currentChildToCheck].parent != address(0)) {
                    // If the current child has a parent, we calculate the parent reward
                    // The first child is the caller of the function
                    int256 layer = int256(i + 1);
                    uint256 currentParentRewardRatio = _ambassadorRewardRatioByLayer(layer);
                    uint256 currentParentReward = (contribution * currentParentRewardRatio) /
                        (100 * DECIMAL_CORRECTION);

                    address childParent = prePaidMembers[currentChildToCheck].parent;

                    // Then if the current child is already KYCed, we transfer the parent reward
                    if (isChildKYCed[currentChildToCheck]) {
                        parentRewardsByChild[childParent][currentChildToCheck] = 0;
                        usdc.safeTransfer(childParent, currentParentReward);
                        emit OnParentRewarded(childParent, msg.sender, currentParentReward);
                    } else {
                        // Otherwise, we store the parent reward in the parentRewardsByChild mapping
                        parentRewardsByChild[childParent][
                            currentChildToCheck
                        ] = currentParentReward;
                    }
                    // And the reward to the parent layer
                    parentRewardsByLayer[childParent][uint256(layer)] += currentParentReward;
                    // Lastly, we update the currentChildToCheck variable and the paymentCollectedFees
                    currentChildToCheck = childParent;
                    paymentCollectedFees -= currentParentReward;
                } else {
                    // Otherwise, we break the loop
                    break;
                }
            }
        }

        collectedFees += paymentCollectedFees;
        daoDatas[tDaoName].currentAmount += contribution;
        emit OnPrePayment(parent, msg.sender, contribution);
    }

    /**
     * @notice Join a tDAO
     * @param newMember The address of the new member
     * @dev The member must be KYCed
     * @dev The member must have a parent
     * @dev The member must have a tDAO assigned
     */
    function joinDao(address newMember) external {
        // Initial checks
        PrePaidMember memory member = prePaidMembers[newMember];
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
            uint256 parentReward = parentRewardsByChild[parent][newMember];

            if (parentReward > 0) {
                parentRewardsByChild[parent][newMember] = 0;
                usdc.safeTransfer(parent, parentReward);

                emit OnParentRewarded(parent, newMember, parentReward);
            }
        }

        // Finally, we join the member to the tDAO
        ITakasurePool(dao.daoAddress).joinByReferral(
            newMember,
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
            uint256 parentReward = parentRewardsByChild[parent][child];
            parentRewardsByChild[parent][child] = 0;

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

    function withdrawFees() external onlyRole(TAKADAO_OPERATOR) {
        uint256 _collectedFees = collectedFees;
        collectedFees = 0;
        usdc.safeTransfer(takadaoOperator, _collectedFees);
    }

    function getDaoData(string calldata tDaoName) external view returns (Dao memory) {
        return daoDatas[tDaoName];
    }

    /**
     * @notice This function calculates the ambassador reward ratio based on the layer
     * @param _layer The layer of the ambassador
     * @return ambassadorRewardRatio_ The ambassador reward ratio
     * @dev Max Layer = 4
     * @dev The formula is y = Ax^3 + Bx^2 + Cx + D
     *      y = reward ratio, x = layer, A = -3_125, B = 30_500, C = -99_625, D = 112_250
     *      The original values are layer 1 = 4%, layer 2 = 1%, layer 3 = 0.35%, layer 4 = 0.175%
     *      But this values where multiplied by 10_000 to avoid decimals in the formula so the values are
     *      layer 1 = 40_000, layer 2 = 10_000, layer 3 = 3_500, layer 4 = 1_750
     */
    function _ambassadorRewardRatioByLayer(
        int256 _layer
    ) internal pure returns (uint256 ambassadorRewardRatio_) {
        // ambassadorRewardRatio_ = uint256(
        //     (A * (_layer ** 3)) + (B * (_layer ** 2)) + (C * _layer) + D
        // );
        assembly {
            let layerSquare := mul(_layer, _layer)
            let layerCube := mul(_layer, layerSquare)

            ambassadorRewardRatio_ := add(
                add(add(mul(A, layerCube), mul(B, layerSquare)), mul(C, _layer)),
                D
            )
        }
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(TAKADAO_OPERATOR) {}
}
