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
import {IBenefitMultiplierConsumer} from "contracts/interfaces/IBenefitMultiplierConsumer.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

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
    IBenefitMultiplierConsumer private bmConsumer;

    uint8 public constant SERVICE_FEE_RATIO = 22;
    uint256 public constant CONTRIBUTION_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee
    uint256 public constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution deducted from contribution
    uint256 public constant REPOOL_FEE_RATIO = 2; // 2% of contribution deducted from fee
    uint256 private constant MINIMUM_CONTRIBUTION = 25e6; // 25 USDC
    uint256 private constant MAXIMUM_CONTRIBUTION = 250e6; // 250 USDC
    // For the referrals reward ratio
    int256 private constant MAX_TIER = 4;
    int256 private constant A = -3_125;
    int256 private constant B = 30_500;
    int256 private constant C = -99_625;
    int256 private constant D = 112_250;
    uint256 private constant DECIMAL_CORRECTION = 10_000;

    address private operator;

    bytes32 private constant OPERATOR = keccak256("OPERATOR");
    bytes32 public constant KYC_PROVIDER = keccak256("KYC_PROVIDER");
    bytes32 private constant COFOUNDER_OF_CHANGE = keccak256("COFOUNDER_OF_CHANGE");

    mapping(address parent => mapping(address child => uint256 rewards))
        public parentRewardsByChild;
    mapping(address parent => mapping(uint256 layer => uint256 rewards))
        public parentRewardsByLayer;
    mapping(address child => PrepaidMember) public prepaidMembers;
    mapping(string tDAOName => tDAO DAOData) private nameToDAOData;
    mapping(address child => bool) public isChildKYCed;

    struct PrepaidMember {
        string tDAOName;
        address child;
        address parent;
        uint256 contributionBeforeFee;
        uint256 contributionAfterFee;
        uint256 actualFee; // Fee received in the contract
        uint256 discount;
    }

    struct tDAO {
        string name;
        bool isPreJoinEnabled;
        address prepaymentAdmin; // The one that can modify the DAO settings
        address DAOAddress; // To be assigned when the tDAO is deployed
        address rePoolAddress; // To be assigned when the tDAO is deployed
        uint256 launchDate; // in seconds
        uint256 objectiveAmount; // in USDC, six decimals
        uint256 currentAmount; // in USDC, six decimals
        uint256 collectedFees; // in USDC, six decimals
        uint256 feeToRepool; // in USDC, six decimals
        uint256 feeToOperator; // in USDC, six decimals
    }

    event OnPreJoinEnabledChanged(bool indexed isPreJoinEnabled);
    event OnNewReferral(address indexed referral);
    event OnNewCofounderOfChange(address indexed cofounderOfChange);
    event Onprepayment(address indexed parent, address indexed child, uint256 indexed contribution);
    event OnParentRewarded(address indexed parent, address indexed child, uint256 indexed reward);
    event OnChildKycVerified(address indexed child);
    event OnBenefitMultiplierConsumerChanged(
        address indexed newBenefitMultiplierConsumer,
        address indexed oldBenefitMultiplierConsumer
    );

    error ReferralGateway__ZeroAddress();
    error ReferralGateway__ContributionOutOfRange();
    error ReferralGateway__MemberAlreadyKYCed();
    error ReferralGateway__NotAllowedToPrePay();
    error ReferralGateway__NotKYCed();
    error ReferralGateway__tDAOAddressNotAssignedYet();
    error ReferralGateway__onlyDAOAdmin();
    error ReferralGateway__HasNotPaid();
    error ReferralGateway__BenefitMultiplierRequestFailed(bytes errorResponse);

    modifier notZeroAddress(address _address) {
        if (_address == address(0)) revert ReferralGateway__ZeroAddress();
        _;
    }

    modifier onlyDAOAdmin(string calldata tDAOName) {
        if (nameToDAOData[tDAOName].prepaymentAdmin != msg.sender)
            revert ReferralGateway__onlyDAOAdmin();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _operator,
        address _kycProvider,
        address _usdcAddress,
        address _benefitMultiplierConsumer
    ) external notZeroAddress(_operator) notZeroAddress(_usdcAddress) initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuardTransient_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _operator);
        _grantRole(OPERATOR, _operator);
        _grantRole(KYC_PROVIDER, _kycProvider);

        bmConsumer = IBenefitMultiplierConsumer(_benefitMultiplierConsumer);

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
    function createDAO(
        string calldata DAOName,
        bool _isPreJoinEnabled,
        uint256 launchDate,
        uint256 objectiveAmount
    ) external {
        // Create the new DAO
        tDAO memory DAO = tDAO({
            name: DAOName, // To be used as a key
            isPreJoinEnabled: _isPreJoinEnabled,
            prepaymentAdmin: msg.sender,
            DAOAddress: address(0), // To be assigned when the tDAO is deployed
            rePoolAddress: address(0), // To be assigned when the tDAO is deployed
            launchDate: launchDate, // in seconds
            objectiveAmount: objectiveAmount,
            currentAmount: 0,
            collectedFees: 0,
            feeToRepool: 0,
            feeToOperator: 0
        });

        // Update the necessary mappings
        nameToDAOData[DAO.name] = DAO;
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
    function assignTDAOAddress(
        string calldata tDAOName,
        address tDAOAddress
    ) external notZeroAddress(tDAOAddress) onlyDAOAdmin(tDAOName) {
        nameToDAOData[tDAOName].DAOAddress = tDAOAddress;
    }

    /**
     * @notice Assign a rePool address to a tDAO name
     * @param tDAOName The name of the tDAO
     */
    function assignRePoolAddress(
        string calldata tDAOName,
        address rePoolAddress
    ) external notZeroAddress(rePoolAddress) onlyDAOAdmin(tDAOName) {
        nameToDAOData[tDAOName].rePoolAddress = rePoolAddress;
    }

    /**
     * @notice Assign a launch date to a tDAO
     * @param tDAOName The name of the tDAO
     * @param launchDate The launch date of the tDAO
     * @dev The launch date must be in seconds
     */
    function assignTDAOLaunchDate(
        string calldata tDAOName,
        uint256 launchDate
    ) external onlyDAOAdmin(tDAOName) {
        nameToDAOData[tDAOName].launchDate = launchDate;
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
    function prepay(uint256 contribution, string calldata tDAOName, address parent) external {
        tDAO memory DAO = nameToDAOData[tDAOName];
        // Initial checks
        if (!DAO.isPreJoinEnabled) revert ReferralGateway__NotAllowedToPrePay();
        if (contribution < MINIMUM_CONTRIBUTION || contribution > MAXIMUM_CONTRIBUTION)
            revert ReferralGateway__ContributionOutOfRange();
        // Calculate the fee and create the new pre-paid member
        uint256 fee = (contribution * SERVICE_FEE_RATIO) / 100;
        uint256 rePoolFee = (contribution * REPOOL_FEE_RATIO) / 100;
        uint256 discount = (contribution * CONTRIBUTION_DISCOUNT_RATIO) / 100;
        uint256 amountToTransfer = contribution - discount;

        // The discount is deducted from the fee
        fee -= discount;

        PrepaidMember memory prepaidMember = PrepaidMember({
            tDAOName: tDAOName,
            child: msg.sender,
            parent: parent,
            contributionBeforeFee: contribution, // Input value, we need it like this for the actual join when the DAO is deployed
            contributionAfterFee: contribution - fee, // Without discount, we need it like this for the actual join when the DAO is deployed
            actualFee: fee, // For now only the fee - discount
            discount: discount // For now only the discount. 10% of the contribution for every pre-payment
        });

        // We store the new member
        prepaidMembers[msg.sender] = prepaidMember;

        // We check if the parent is valid
        if (parent != address(0) && isChildKYCed[parent]) {
            // We give an extra discount to the contribution
            uint256 referralDiscount = (contribution * REFERRAL_DISCOUNT_RATIO) / 100;

            // This discount is not deducted from the fee
            prepaidMembers[msg.sender].discount += referralDiscount;
            amountToTransfer -= referralDiscount;

            address currentChildToCheck = msg.sender;
            for (int256 i; i < MAX_TIER; ++i) {
                if (
                    prepaidMembers[currentChildToCheck].parent == address(0) ||
                    !isChildKYCed[prepaidMembers[currentChildToCheck].parent]
                ) {
                    break;
                }
                uint256 currentParentReward = (contribution * _referralRewardRatioByLayer(i + 1)) /
                    (100 * DECIMAL_CORRECTION);
                address currentChildParent = prepaidMembers[currentChildToCheck].parent;
                // And we store the parent reward and the reward to the parent layer
                parentRewardsByChild[currentChildParent][msg.sender] = currentParentReward;
                parentRewardsByLayer[currentChildParent][uint256(i + 1)] += currentParentReward;
                // This rewards are taken from the fee
                fee -= currentParentReward;
                // Lastly, we update the currentChildToCheck variable
                currentChildToCheck = currentChildParent;
            }
        }

        // We transfer the contribution to the contract, this way we have funds to pay the parent rewards
        usdc.safeTransferFrom(msg.sender, address(this), amountToTransfer);

        // We update the fee for the member
        prepaidMembers[msg.sender].actualFee = fee;

        // Update the values for the DAO
        nameToDAOData[tDAOName].collectedFees += fee;
        nameToDAOData[tDAOName].feeToRepool += rePoolFee;
        nameToDAOData[tDAOName].feeToOperator += fee - rePoolFee;
        nameToDAOData[tDAOName].currentAmount += amountToTransfer;

        // Finally, we request the benefit multiplier for the member, this to have it ready when the member joins the DAO
        _getBenefitMultiplierFromOracle(msg.sender);

        emit Onprepayment(parent, msg.sender, contribution);
    }

    /**
     * @notice Set the KYC status of a member
     * @param child The address of the member
     * @dev Only the KYC_PROVIDER can set the KYC status
     */
    function setKYCStatus(address child) external notZeroAddress(child) onlyRole(KYC_PROVIDER) {
        // Initial checks
        PrepaidMember memory member = prepaidMembers[child];
        // Can not KYC a member that is already KYCed
        if (isChildKYCed[child]) revert ReferralGateway__MemberAlreadyKYCed();

        // The member must have already pre-paid
        if (member.contributionBeforeFee == 0) revert ReferralGateway__HasNotPaid();

        // Update the KYC status
        isChildKYCed[child] = true;

        address parent = member.parent;

        for (uint256 i; i < uint256(MAX_TIER); ++i) {
            if (parent == address(0)) break;

            uint256 parentReward = parentRewardsByChild[parent][child];

            parentRewardsByChild[parent][child] = 0;
            usdc.safeTransfer(parent, parentReward);

            emit OnParentRewarded(parent, child, parentReward);

            // We update the parent address to check the next parent
            parent = prepaidMembers[parent].parent;
        }

        emit OnChildKycVerified(child);
    }

    /**
     * @notice Join a tDAO
     * @param newMember The address of the new member
     * @dev The member must be KYCed
     * @dev The member must have a parent
     * @dev The member must have a tDAO assigned
     */
    function joinDAO(address newMember) external nonReentrant {
        // Initial checks
        PrepaidMember memory member = prepaidMembers[newMember];
        tDAO memory DAO = nameToDAOData[member.tDAOName];

        if (DAO.DAOAddress == address(0)) revert ReferralGateway__tDAOAddressNotAssignedYet();

        if (!isChildKYCed[member.child]) revert ReferralGateway__NotKYCed();

        // Finally, we join the member to the tDAO
        ITakasurePool(DAO.DAOAddress).joinByReferral(
            newMember,
            member.contributionBeforeFee,
            member.contributionAfterFee
        );

        usdc.safeTransfer(DAO.DAOAddress, member.contributionAfterFee);
    }

    function setPreJoinEnabled(
        string calldata tDAOName,
        bool _isPreJoinEnabled
    ) external onlyDAOAdmin(tDAOName) {
        nameToDAOData[tDAOName].isPreJoinEnabled = _isPreJoinEnabled;
        emit OnPreJoinEnabledChanged(_isPreJoinEnabled);
    }

    function setUsdcAddress(address _usdcAddress) external onlyRole(OPERATOR) {
        usdc = IERC20(_usdcAddress);
    }

    function setNewBenefitMultiplierConsumer(
        address newBenefitMultiplierConsumer
    ) external onlyRole(OPERATOR) notZeroAddress(newBenefitMultiplierConsumer) {
        address oldBenefitMultiplierConsumer = address(bmConsumer);
        bmConsumer = IBenefitMultiplierConsumer(newBenefitMultiplierConsumer);

        emit OnBenefitMultiplierConsumerChanged(
            newBenefitMultiplierConsumer,
            oldBenefitMultiplierConsumer
        );
    }

    function withdrawFees(string calldata tDAOName) external onlyRole(OPERATOR) {
        uint256 _feeToOperator = nameToDAOData[tDAOName].feeToOperator;
        uint256 _feeToRepool = nameToDAOData[tDAOName].feeToRepool;
        if (_feeToOperator > 0) {
            nameToDAOData[tDAOName].collectedFees -= _feeToOperator;
            nameToDAOData[tDAOName].feeToOperator = 0;
            usdc.safeTransfer(operator, _feeToOperator);
        }
        if (_feeToRepool > 0) {
            address _rePoolAddress = nameToDAOData[tDAOName].rePoolAddress;
            if (_rePoolAddress != address(0)) {
                nameToDAOData[tDAOName].collectedFees -= _feeToRepool;
                nameToDAOData[tDAOName].feeToRepool = 0;
                usdc.safeTransfer(_rePoolAddress, _feeToRepool);
            }
        }
    }

    function getDAOData(string calldata tDAOName) external view returns (tDAO memory) {
        return nameToDAOData[tDAOName];
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

    function _getBenefitMultiplierFromOracle(address _member) internal {
        string memory memberAddressToString = Strings.toHexString(uint256(uint160(_member)), 20);
        string[] memory args = new string[](1);
        args[0] = memberAddressToString;
        bmConsumer.sendRequest(args);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(OPERATOR) {}
}
