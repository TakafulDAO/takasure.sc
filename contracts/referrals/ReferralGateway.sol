// SPDX-License-Identifier: GPL-3.0

/**
 * @title ReferralGateway
 * @author Maikel Ordaz
 * @dev This contract will manage all the functionalities related to the referral system and pre-joins
 *      to the LifeDAO protocol
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITakasurePool} from "contracts/interfaces/ITakasurePool.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.25;

/// @custom:oz-upgrades-from contracts/version_previous_contracts/ReferralGatewayV1.sol:ReferralGatewayV1
contract ReferralGateway is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransientUpgradeable
{
    using SafeERC20 for IERC20;

    IERC20 public usdc;

    uint8 public constant SERVICE_FEE_RATIO = 22;
    uint256 public constant CONTRIBUTION_DISCOUNT_RATIO = 5;
    uint256 private constant MINIMUM_CONTRIBUTION = 25e6; // 25 USDC
    uint256 private constant MAXIMUM_CONTRIBUTION = 250e6; // 250 USDC
    // For the ambassadors reward ratio
    uint256 private constant MAX_TIER = 4;
    int256 private constant A = -3_125;
    int256 private constant B = 30_500;
    int256 private constant C = -99_625;
    int256 private constant D = 112_250;
    uint256 private constant DECIMAL_CORRECTION = 10_000;

    address private operator;

    bytes32 private constant OPERATOR = keccak256("OPERATOR");
    bytes32 public constant KYC_PROVIDER = keccak256("KYC_PROVIDER");
    bytes32 private constant AMBASSADOR = keccak256("AMBASSADOR");
    bytes32 private constant COFOUNDER_OF_CHANGE = keccak256("COFOUNDER_OF_CHANGE");

    mapping(address parent => mapping(address child => uint256 rewards))
        public parentRewardsByChild;
    mapping(address parent => mapping(uint256 layer => uint256 rewards))
        public parentRewardsByLayer;
    mapping(address child => PrepaidMember) public prepaidMembers;
    mapping(string tDAOName => tDAO DAOData) private DAODatas;
    mapping(address child => bool) public isChildKYCed;

    struct PrepaidMember {
        string tDAOName;
        address child;
        address parent;
        uint256 contributionBeforeFee;
        uint256 contributionAfterFee;
        uint256 actualFee;
    }

    struct tDAO {
        string name;
        bool isPreJoinEnabled;
        address prePaymentAdmin; // The one that can modify the DAO settings
        address daoAddress; // To be assigned when the tDAO is deployed
        uint256 launchDate; // in seconds
        uint256 objectiveAmount; // in USDC, six decimals
        uint256 currentAmount; // in USDC, six decimals
        uint256 collectedFees; // in USDC, six decimals
    }

    event OnPreJoinEnabledChanged(bool indexed isPreJoinEnabled);
    event OnNewAmbassador(address indexed ambassador);
    event OnNewCofounderOfChange(address indexed cofounderOfChange);
    event OnPrePayment(address indexed parent, address indexed child, uint256 indexed contribution);
    event OnParentRewarded(address indexed parent, address indexed child, uint256 indexed reward);
    event OnChildKycVerified(address indexed child);

    error ReferralGateway__ZeroAddress();
    error ReferralGateway__ContributionOutOfRange();
    error ReferralGateway__MemberAlreadyKYCed();
    error ReferralGateway__NotAllowedToPrePay();
    error ReferralGateway__NotKYCed();
    error ReferralGateway__tDAOAddressNotAssignedYet();
    error ReferralGateway__onlyDaoAdmin();

    modifier notZeroAddress(address _address) {
        if (_address == address(0)) {
            revert ReferralGateway__ZeroAddress();
        }
        _;
    }

    modifier onlyDaoAdmin(string calldata tDAOName) {
        if (DAODatas[tDAOName].prePaymentAdmin != msg.sender) {
            revert ReferralGateway__onlyDaoAdmin();
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _operator,
        address _kycProvider,
        address _usdcAddress
    ) external notZeroAddress(_operator) notZeroAddress(_usdcAddress) initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuardTransient_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _operator);
        _grantRole(OPERATOR, _operator);
        _grantRole(KYC_PROVIDER, _kycProvider);

        operator = _operator;
        // isPreJoinEnabled = true;
        usdc = IERC20(_usdcAddress);
    }

    /**
     * @notice Create a new DAO
     * @param DAOName The name of the DAO
     * @param _isPreJoinEnabled The pre-join status of the DAO
     * @param launchDate The launch date of the DAO
     * @param objectiveAmount The objective amount of the DAO
     * @dev The launch date must be in seconds
     * @dev The launch date can be 0, if the DAO is already launched or the launch date is not defined
     * @dev The objective amount must be in USDC, six decimals
     * @dev The objective amount can be 0, if the DAO is already launched or the objective amount is not defined
     */
    function createDao(
        string calldata DAOName,
        bool _isPreJoinEnabled,
        uint256 launchDate,
        uint256 objectiveAmount
    ) external {
        // Create the new DAO
        tDAO memory dao = tDAO({
            name: DAOName, // To be used as a key
            isPreJoinEnabled: _isPreJoinEnabled,
            prePaymentAdmin: msg.sender,
            daoAddress: address(0), // To be assigned when the tDAO is deployed
            launchDate: launchDate, // in seconds
            objectiveAmount: objectiveAmount,
            currentAmount: 0,
            collectedFees: 0
        });

        // Update the necessary mappings
        DAODatas[dao.name] = dao;
    }

    /**
     * @notice Register an ambassador
     * @param ambassador The address to register as ambassador
     * @dev Only the OPERATOR can register an ambassador
     */
    function registerAmbassador(
        address ambassador
    ) external notZeroAddress(ambassador) onlyRole(OPERATOR) {
        _grantRole(AMBASSADOR, ambassador);

        emit OnNewAmbassador(ambassador);
    }

    /**
     * @notice Register a Cofounder of Change
     * @param cofounderOfChange The address to register as cofounderOfChange
     * @dev Only the OPERATOR can register an cofounderOfChange
     */
    function registerCofounderOfChange(
        address cofounderOfChange
    ) external notZeroAddress(cofounderOfChange) onlyRole(OPERATOR) {
        _grantRole(COFOUNDER_OF_CHANGE, cofounderOfChange);

        emit OnNewCofounderOfChange(cofounderOfChange);
    }

    /**
     * @notice Assign a tDAO address to a tDAO name
     * @param tDAOName The name of the tDAO
     */
    function assignTDaoAddress(
        string calldata tDAOName,
        address tdaoAddress
    ) external notZeroAddress(tdaoAddress) onlyDaoAdmin(tDAOName) {
        DAODatas[tDAOName].daoAddress = tdaoAddress;
    }

    /**
     * @notice Pre pay for a membership
     * @param parent The address of the parent
     * @param contribution The amount to pay
     * @param tDAOName The name of the tDAO
     * @dev The parent address is optional
     * @dev The contribution must be between 25 and 250 USDC
     * @dev The parent reward ratio depends on the parent role
     */
    function prePayment(uint256 contribution, string calldata tDAOName, address parent) external {
        tDAO memory dao = DAODatas[tDAOName];
        // Initial checks
        if (!dao.isPreJoinEnabled) {
            revert ReferralGateway__NotAllowedToPrePay();
        }

        if (contribution < MINIMUM_CONTRIBUTION || contribution > MAXIMUM_CONTRIBUTION) {
            revert ReferralGateway__ContributionOutOfRange();
        }

        // Calculate the fee and create the new pre-paid member
        uint256 fee = (contribution * SERVICE_FEE_RATIO) / 100;
        uint256 paymentCollectedFees;

        PrepaidMember memory prepaidMember = PrepaidMember({
            tDAOName: tDAOName,
            child: msg.sender,
            parent: parent,
            contributionBeforeFee: contribution, // Input value
            contributionAfterFee: contribution - fee, // Without discount, we need it like this for the actual join when the dao is deployed
            actualFee: 0 // If has a parent, it is the fee - discount. Otherwise, it is the fee
        });

        // As the parent is optional, we need to check if it is not zero
        if (parent != address(0)) {
            // The user gets a discount if he has a parent
            uint256 discount = (contribution * CONTRIBUTION_DISCOUNT_RATIO) / 100;
            paymentCollectedFees = fee - discount;

            // We update the fee in the prepaidMember struct
            prepaidMember.actualFee = paymentCollectedFees;
            // Update the values for the prepaidMember
            prepaidMembers[msg.sender] = prepaidMember;

            // Transfer the contribution from input minus the discount
            usdc.safeTransferFrom(msg.sender, address(this), contribution - discount);

            address currentChildToCheck = msg.sender;
            // We loop through the parent chain up to 4 tiers back
            for (uint256 i; i < MAX_TIER; ++i) {
                // We need to check child by child if it has a parent
                if (prepaidMembers[currentChildToCheck].parent != address(0)) {
                    // If the current child has a parent, we calculate the parent reward
                    // The first child is the caller of the function
                    int256 layer = int256(i + 1);
                    uint256 currentParentRewardRatio = _ambassadorRewardRatioByLayer(layer);
                    uint256 currentParentReward = (contribution * currentParentRewardRatio) /
                        (100 * DECIMAL_CORRECTION);

                    address childParent = prepaidMembers[currentChildToCheck].parent;

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
                    // Lastly, we update the currentChildToCheck variable
                    currentChildToCheck = childParent;
                } else {
                    // Otherwise, we break the loop
                    break;
                }
            }
        } else {
            // The user dont get a discount if there is no parent
            // We update the fee in the prepaidMember struct and transfer the contribution
            paymentCollectedFees = fee;
            prepaidMember.actualFee = fee;
            // Update the values for the prepaidMember
            prepaidMembers[msg.sender] = prepaidMember;

            usdc.safeTransferFrom(msg.sender, address(this), contribution);
        }

        // Update the values for the DAO
        DAODatas[tDAOName].collectedFees += paymentCollectedFees;
        DAODatas[tDAOName].currentAmount += contribution;
        emit OnPrePayment(parent, msg.sender, contribution);
    }

    /**
     * @notice Join a tDAO
     * @param newMember The address of the new member
     * @dev The member must be KYCed
     * @dev The member must have a parent
     * @dev The member must have a tDAO assigned
     */
    function joinDao(address newMember) external nonReentrant {
        // Initial checks
        PrepaidMember memory member = prepaidMembers[newMember];
        tDAO memory dao = DAODatas[member.tDAOName];

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
        PrepaidMember memory member = prepaidMembers[child];
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
        string calldata tDAOName,
        bool _isPreJoinEnabled
    ) external onlyDaoAdmin(tDAOName) {
        DAODatas[tDAOName].isPreJoinEnabled = _isPreJoinEnabled;
        emit OnPreJoinEnabledChanged(_isPreJoinEnabled);
    }

    function setUsdcAddress(address _usdcAddress) external onlyRole(OPERATOR) {
        usdc = IERC20(_usdcAddress);
    }

    function withdrawFees(string calldata tDAOName) external onlyRole(OPERATOR) {
        uint256 _collectedFees = DAODatas[tDAOName].collectedFees;
        DAODatas[tDAOName].collectedFees = 0;
        usdc.safeTransfer(operator, _collectedFees);
    }

    function getDaoData(string calldata tDAOName) external view returns (tDAO memory) {
        return DAODatas[tDAOName];
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
        assembly {
            let layerSquare := mul(_layer, _layer) // x^2
            let layerCube := mul(_layer, layerSquare) // x^3

            // y = Ax^3 + Bx^2 + Cx + D
            ambassadorRewardRatio_ := add(
                add(add(mul(A, layerCube), mul(B, layerSquare)), mul(C, _layer)),
                D
            )
        }
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(OPERATOR) {}
}
