// SPDX-License-Identifier: GPL-3.0

/**
 * @title ReferralGateway
 * @author Maikel Ordaz
 * @dev This contract will manage all the functionalities related to the referral system and pre-joins
 *      to the LifeDao protocol
 * @dev Upgradeable contract with UUPS pattern
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.25;

contract ReferralGateway is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 private usdc;

    uint8 public constant SERVICE_FEE = 22;
    uint256 private constant MINIMUM_SERVICE_FEE = 25e6; // 25 USDC
    uint256 private constant MAXIMUM_SERVICE_FEE = 250e6; // 250 USDC
    uint8 public defaultRewardRatio;
    uint8 public memberRewardRatio;
    uint8 public ambassadorRewardRatio;

    bool public isPreJoinEnabled;

    uint256 private collectedFees;
    address private takadaoOperator;

    bytes32 private constant TAKADAO_OPERATOR = keccak256("TAKADAO_OPERATOR");
    bytes32 public constant KYC_PROVIDER = keccak256("KYC_PROVIDER");
    bytes32 private constant MEMBER = keccak256("MEMBER");
    bytes32 private constant AMBASSADOR = keccak256("AMBASSADOR");

    mapping(address proposedAmbassador => bool) public proposedAmbassadors;
    mapping(address parent => mapping(address child => uint256 rewards)) public parentRewards;
    mapping(uint256 childCounter => address child) public childs;
    mapping(address child => PrePaidMember) public prePaidMembers;

    struct PrePaidMember {
        bool isChildKYCed;
        address tDAO;
        address parent;
        uint256 contributionBeforeFee;
        uint256 contributionAfterFee;
    }

    uint256 private childCounter;

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
    error ReferralGateway__FailedToJoin();

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
    }

    function proposeAsAmbassador() external {
        _proposeAsAmbassador(msg.sender);
    }

    function proposeAsAmbassador(
        address propossedAmbassador
    ) external notZeroAddress(propossedAmbassador) {
        _proposeAsAmbassador(propossedAmbassador);
    }

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

    function prePaymentWithReferral(address parent, uint256 contribution, address tDAO) external {
        if (!isPreJoinEnabled) {
            revert ReferralGateway__NotAllowedToPrePay();
        }

        if (contribution < MINIMUM_SERVICE_FEE || contribution > MAXIMUM_SERVICE_FEE) {
            revert ReferralGateway__ContributionOutOfRange();
        }
        uint256 rewardRatio;
        if (hasRole(AMBASSADOR, parent)) {
            rewardRatio = ambassadorRewardRatio;
        } else if (hasRole(MEMBER, parent)) {
            rewardRatio = memberRewardRatio;
        } else {
            rewardRatio = defaultRewardRatio;
        }
        uint256 fee = (contribution * SERVICE_FEE) / 100;
        uint256 parentReward = (fee * rewardRatio) / 100;

        parentRewards[parent][msg.sender] = parentReward;
        collectedFees += fee;

        if (prePaidMembers[msg.sender].isChildKYCed) {
            prePaidMembers[msg.sender].tDAO = tDAO;
            prePaidMembers[msg.sender].parent = parent;
            prePaidMembers[msg.sender].contributionBeforeFee = contribution;
            prePaidMembers[msg.sender].contributionAfterFee = contribution - fee;

            parentRewards[parent][msg.sender] = 0;
            usdc.safeTransferFrom(msg.sender, address(this), contribution);
            usdc.safeTransfer(parent, parentReward);

            emit OnParentRewarded(parent, msg.sender, parentReward);
        } else {
            ++childCounter;

            PrePaidMember memory prePaidMember = PrePaidMember({
                isChildKYCed: false,
                tDAO: tDAO,
                parent: parent,
                contributionBeforeFee: contribution,
                contributionAfterFee: contribution - fee
            });

            childs[childCounter] = msg.sender;
            prePaidMembers[msg.sender] = prePaidMember;
            usdc.safeTransferFrom(msg.sender, address(this), contribution);
        }

        emit OnPrePayment(parent, msg.sender, contribution);
    }

    function joinDao() external {
        PrePaidMember memory member = prePaidMembers[msg.sender];
        if (!member.isChildKYCed) {
            revert ReferralGateway__NotKYCed();
        }
        if (!isPreJoinEnabled) {
            revert ReferralGateway__NotAllowedToPrePay();
        }

        address parent = member.parent;
        uint256 parentReward = parentRewards[parent][msg.sender];

        if (parentReward > 0) {
            parentRewards[parent][msg.sender] = 0;
            usdc.safeTransfer(parent, parentReward);

            emit OnParentRewarded(parent, msg.sender, parentReward);
        }

        (bool success, ) = member.tDAO.call(
            abi.encodeWithSignature(
                "joinByReferral(address,uint256,uint256)",
                msg.sender,
                member.contributionBeforeFee,
                member.contributionAfterFee
            )
        );
        if (!success) {
            revert ReferralGateway__FailedToJoin();
        }

        usdc.safeTransfer(member.tDAO, member.contributionAfterFee);
    }

    function setKYCStatus(address child) external notZeroAddress(child) onlyRole(KYC_PROVIDER) {
        PrePaidMember memory member = prePaidMembers[child];
        if (member.isChildKYCed) {
            revert ReferralGateway__MemberAlreadyKYCed();
        }

        prePaidMembers[child].isChildKYCed = true;

        if (member.contributionBeforeFee > 0) {
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
        usdc.safeTransfer(takadaoOperator, collectedFees);
        collectedFees = 0;
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
