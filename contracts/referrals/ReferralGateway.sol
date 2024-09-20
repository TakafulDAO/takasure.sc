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
    uint8 public defaultRewardRatio;
    uint8 public memberRewardRatio;
    uint8 public ambassadorRewardRatio;

    bool public isPreJoinEnabled;

    uint256 public collectedFees;
    address private takadaoOperator;

    bytes32 private constant TAKADAO_OPERATOR = keccak256("TAKADAO_OPERATOR");
    bytes32 public constant KYC_PROVIDER = keccak256("KYC_PROVIDER");
    bytes32 private constant AMBASSADOR = keccak256("AMBASSADOR");

    mapping(address proposedAmbassador => bool) public proposedAmbassadors;
    mapping(address parent => mapping(address child => uint256 rewards)) public parentRewards;
    mapping(uint256 childCounter => address child) public childs;
    mapping(address child => PrePaidMember) public prePaidMembers;
    mapping(string tDAOName => address tDAO) public tDAOs;
    mapping(address child => bool) public isChildKYCed;

    struct PrePaidMember {
        string tDAOName;
        address child;
        address parent;
        uint256 contributionBeforeFee;
        uint256 contributionAfterFee;
    }

    uint256 public childCounter;

    event OnPreJoinEnabledChanged(bool indexed isPreJoinEnabled);
    event OnNewAmbassadorProposal(address indexed proposedAmbassador);
    event OnNewAmbassador(address indexed ambassador);
    event OnPrePayment(address indexed parent, address indexed child, uint256 indexed contribution);
    event OnParentRewarded(address indexed parent, address indexed child, uint256 indexed reward);
    event OnChildKycVerified(address indexed child);

    error ReferralGateway__ZeroAddress();
    error ReferralGateway__OnlyProposedAmbassadors();
    error ReferralGateway__ContributionOutOfRange();
    error ReferralGateway__MemberAlreadyKYCed();
    error ReferralGateway__NotAllowedToPrePay();
    error ReferralGateway__NotKYCed();
    error ReferralGateway__tDAOAddressNotAssignedYet();

    modifier notZeroAddress(address _address) {
        if (_address == address(0)) {
            revert ReferralGateway__ZeroAddress();
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
        isPreJoinEnabled = true;
        usdc = IERC20(_usdcAddress);

        defaultRewardRatio = 1;
        memberRewardRatio = 20;
        ambassadorRewardRatio = 5;
    }

    /**
     * @notice Propose self as ambassador
     */
    function proposeAsAmbassador() external {
        _proposeAsAmbassador(msg.sender);
    }

    /**
     * @notice Propose an address as ambassador
     * @param propossedAmbassador The address to propose as ambassador
     */
    function proposeAsAmbassador(
        address propossedAmbassador
    ) external notZeroAddress(propossedAmbassador) {
        _proposeAsAmbassador(propossedAmbassador);
    }

    /**
     * @notice Approve an address as ambassador
     * @param ambassador The address to approve as ambassador
     * @dev Only the TAKADAO_OPERATOR can approve an ambassador
     */
    function approveAsAmbassador(
        address ambassador
    ) external notZeroAddress(ambassador) onlyRole(TAKADAO_OPERATOR) {
        if (!proposedAmbassadors[ambassador]) {
            revert ReferralGateway__OnlyProposedAmbassadors();
        }
        _grantRole(AMBASSADOR, ambassador);
        proposedAmbassadors[ambassador] = false;

        emit OnNewAmbassador(ambassador);
    }

    /**
     * @notice Assign a tDAO address to a tDAO name
     * @param tDAOName The name of the tDAO
     */
    function assignTDaoAddress(
        string calldata tDAOName,
        address tDAOAddress
    ) external notZeroAddress(tDAOAddress) onlyRole(TAKADAO_OPERATOR) {
        tDAOs[tDAOName] = tDAOAddress;
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
    function prePayment(address parent, uint256 contribution, string calldata tDAOName) external {
        // Initial checks
        if (!isPreJoinEnabled) {
            revert ReferralGateway__NotAllowedToPrePay();
        }

        if (contribution < MINIMUM_SERVICE_FEE || contribution > MAXIMUM_SERVICE_FEE) {
            revert ReferralGateway__ContributionOutOfRange();
        }

        // Calculate the fee and create the new pre-paid member
        uint256 fee = (contribution * SERVICE_FEE) / 100;

        ++childCounter;

        PrePaidMember memory prePaidMember = PrePaidMember({
            tDAOName: tDAOName,
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
            } else if (tDAOs[tDAOName] != address(0)) {
                if (
                    ITakasurePool(tDAOs[tDAOName]).getMemberFromAddress(parent).memberState ==
                    MemberState.Active
                ) {
                    rewardRatio = memberRewardRatio;
                } else {
                    rewardRatio = defaultRewardRatio;
                }
            } else {
                rewardRatio = defaultRewardRatio;
            }

            // Calculate the parent reward, the collected fees
            uint256 parentReward = (fee * rewardRatio) / 100;
            collectedFees += fee - parentReward;

            // We check if the parent is child of another parent up to 4 tiers back
            address currentParentToCheck = parent;
            for (uint8 i = 1; i <= MAX_TIER; ++i) {
                if (prePaidMembers[currentParentToCheck].parent != address(0)) {
                    // We calculate the grandParent reward
                    address grandParent = prePaidMembers[currentParentToCheck].parent;
                    uint256 grandParentReward = ((i + 1) * parentReward * rewardRatio) / 100;
                    parentRewards[grandParent][currentParentToCheck] = 0;
                    usdc.safeTransfer(grandParent, grandParentReward);
                    emit OnParentRewarded(grandParent, msg.sender, grandParentReward);
                    currentParentToCheck = grandParent;
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
        } else {
            // If the parent is zero, we store the fee in the collectedFees variable
            collectedFees += fee;
        }

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
        if (tDAOs[member.tDAOName] == address(0)) {
            revert ReferralGateway__tDAOAddressNotAssignedYet();
        }
        if (!isChildKYCed[member.child]) {
            revert ReferralGateway__NotKYCed();
        }
        if (!isPreJoinEnabled) {
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
        address tDAO = tDAOs[member.tDAOName];

        ITakasurePool(tDAO).joinByReferral(
            msg.sender,
            member.contributionBeforeFee,
            member.contributionAfterFee
        );

        usdc.safeTransfer(tDAO, member.contributionAfterFee);
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

    function setPreJoinEnabled(bool _isPreJoinEnabled) external onlyRole(TAKADAO_OPERATOR) {
        isPreJoinEnabled = _isPreJoinEnabled;

        emit OnPreJoinEnabledChanged(_isPreJoinEnabled);
    }

    function setNewMemberRewardRatio(
        uint8 _newMemberRewardRatio
    ) external onlyRole(TAKADAO_OPERATOR) {
        memberRewardRatio = _newMemberRewardRatio;
    }

    function setNewAmbassadorRewardRatio(
        uint8 _newAmbassadorRewardRatio
    ) external onlyRole(TAKADAO_OPERATOR) {
        ambassadorRewardRatio = _newAmbassadorRewardRatio;
    }

    function setNewDefaultRewardRatio(
        uint8 _newDefaultRewardRatio
    ) external onlyRole(TAKADAO_OPERATOR) {
        defaultRewardRatio = _newDefaultRewardRatio;
    }

    function withdrawFees() external onlyRole(TAKADAO_OPERATOR) {
        uint256 _collectedFees = collectedFees;
        collectedFees = 0;
        usdc.safeTransfer(takadaoOperator, _collectedFees);
    }

    function _proposeAsAmbassador(address _propossedAmbassador) internal {
        proposedAmbassadors[_propossedAmbassador] = true;

        emit OnNewAmbassadorProposal(_propossedAmbassador);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(TAKADAO_OPERATOR) {}
}
