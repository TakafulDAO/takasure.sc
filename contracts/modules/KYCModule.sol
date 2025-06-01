//SPDX-License-Identifier: GPL-3.0

/**
 * @title EntryModule
 * @author Maikel Ordaz
 * @notice This contract manage all the process to become a member
 * @dev It will interact with the TakasureReserve contract to update the values
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBenefitMultiplierConsumer} from "contracts/interfaces/IBenefitMultiplierConsumer.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {ISubscriptionModule} from "contracts/interfaces/ISubscriptionModule.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";
import {ReserveAndMemberValuesHook} from "contracts/hooks/ReserveAndMemberValuesHook.sol";
import {MemberPaymentFlow} from "contracts/helpers/payments/MemberPaymentFlow.sol";
import {ParentRewards} from "contracts/helpers/payments/ParentRewards.sol";

import {Reserve, Member, MemberState, ModuleState} from "contracts/types/TakasureTypes.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

pragma solidity 0.8.28;

contract KYCModule is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    TLDModuleImplementation,
    ReserveAndMemberValuesHook,
    MemberPaymentFlow,
    ParentRewards
{
    ITakasureReserve private takasureReserve;
    IBenefitMultiplierConsumer private bmConsumer;
    ISubscriptionModule private subscriptionModule;
    ModuleState private moduleState;

    uint256 private transient normalizedContributionBeforeFee;
    uint256 private transient feeAmount;
    uint256 private transient contributionAfterFee;

    error KYCModule__NoContribution();
    error KYCModule__BenefitMultiplierRequestFailed(bytes errorResponse);
    error KYCModule__MemberAlreadyKYCed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _takasureReserveAddress, address _subscriptionModuleAddress
    ) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuardTransient_init();

        takasureReserve = ITakasureReserve(_takasureReserveAddress);
        bmConsumer = IBenefitMultiplierConsumer(takasureReserve.bmConsumer());
        subscriptionModule = ISubscriptionModule(_subscriptionModuleAddress);

        address takadaoOperator = takasureReserve.takadaoOperator();
        address moduleManager = takasureReserve.moduleManager();

        _grantRole(DEFAULT_ADMIN_ROLE, takadaoOperator);
        _grantRole(ModuleConstants.MODULE_MANAGER, moduleManager);
        _grantRole(ModuleConstants.OPERATOR, takadaoOperator);
        _grantRole(ModuleConstants.KYC_PROVIDER, takasureReserve.kycProvider());
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

    function updateBmAddress() external onlyRole(ModuleConstants.OPERATOR) {
        bmConsumer = IBenefitMultiplierConsumer(takasureReserve.bmConsumer());
    }

    
    /**
     * @notice Approves the KYC for a member.
     * @param memberWallet address of the member
     * @dev It reverts if the member is the zero address
     * @dev It reverts if the member is already KYCed
     */
    function approveKYC(address memberWallet) external onlyRole(ModuleConstants.KYC_PROVIDER) {
        AddressAndStates._onlyModuleState(moduleState, ModuleState.Enabled);
        AddressAndStates._notZeroAddress(memberWallet);

        (Reserve memory reserve, Member memory newMember) = _getReserveAndMemberValuesHook(
            takasureReserve,
            memberWallet
        );

        require(!newMember.isKYCVerified, KYCModule__MemberAlreadyKYCed());
        require(newMember.contribution > 0 && !newMember.isRefunded, KYCModule__NoContribution());

        // This means the user exists and payed contribution but is not KYCed yet, we update the values
        _calculateAmountAndFees(newMember.contribution, reserve.serviceFee);
        uint256 benefitMultiplier = _getBenefitMultiplierFromOracle(memberWallet);

        newMember = _updateMember({
            _drr: reserve.dynamicReserveRatio, // We take the current value
            _benefitMultiplier: benefitMultiplier, // We take the current value
            _membershipDuration: newMember.membershipDuration, // We take the current value
            _memberWallet: memberWallet, // The member wallet
            _memberState: MemberState.Active, // Active state as the user is already paid the contribution and KYCed
            _isKYCVerified: true, // Set to true with this call
            _isRefunded: false, // Remains false as the user is not refunded
            _allowCustomDuration: reserve.allowCustomDuration,
            _member: newMember
        });

        // Then the everyting needed will be updated, proformas, reserves, cash flow,
        // DRR, BMA, tokens minted, no need to transfer the amounts as they are already paid
        uint256 mintedTokens;
        (reserve, mintedTokens) = _memberPaymentFlow({
            _contributionBeforeFee: newMember.contribution,
            _contributionAfterFee: contributionAfterFee,
            _memberWallet: memberWallet,
            _reserve: reserve,
            _takasureReserve: takasureReserve
        });

        newMember.creditTokensBalance += mintedTokens;

        // Reward the parents
        address parent = childToParent[memberWallet];

        for (uint256 i; i < uint256(MAX_TIER); ++i) {
            if (parent == address(0)) break;
            uint256 layer = i + 1;
            uint256 parentReward = parentRewardsByChild[parent][memberWallet];
            // Reset the rewards for this child
            parentRewardsByChild[parent][memberWallet] = 0;
            try IERC20(reserve.contributionToken).transfer(parent, parentReward) {
                emit TakasureEvents.OnParentRewarded(parent, layer, memberWallet, parentReward);
            } catch {
                parentRewardsByChild[parent][memberWallet] = parentReward;
                emit TakasureEvents.OnParentRewardTransferFailed(
                    parent,
                    layer,
                    memberWallet,
                    parentReward
                );
            }
            // We update the parent address to check the next parent
            parent = childToParent[parent];
        }

        emit TakasureEvents.OnMemberKycVerified(newMember.memberId, memberWallet);
        emit TakasureEvents.OnMemberJoined(newMember.memberId, memberWallet);
        _setNewReserveAndMemberValuesHook(takasureReserve, reserve, newMember);
        takasureReserve.memberSurplus(newMember);

    }

    function _calculateAmountAndFees(uint256 _contributionBeforeFee, uint256 _fee) internal {
        // The minimum we can receive is 0,01 USDC, here we round it. This to prevent rounding errors
        // i.e. contributionAmount = (25.123456 / 1e4) * 1e4 = 25.12USDC
        normalizedContributionBeforeFee =
            (_contributionBeforeFee / ModuleConstants.DECIMAL_REQUIREMENT_PRECISION_USDC) *
            ModuleConstants.DECIMAL_REQUIREMENT_PRECISION_USDC;
        feeAmount = (normalizedContributionBeforeFee * _fee) / 100;
        contributionAfterFee = normalizedContributionBeforeFee - feeAmount;
    }

    function _updateMember(
        uint256 _drr,
        uint256 _benefitMultiplier,
        uint256 _membershipDuration,
        address _memberWallet,
        MemberState _memberState,
        bool _isKYCVerified,
        bool _isRefunded,
        bool _allowCustomDuration,
        Member memory _member
    ) internal returns (Member memory) {
        uint256 userMembershipDuration;
        uint256 claimAddAmount = ((normalizedContributionBeforeFee - feeAmount) * (100 - _drr)) /
            100;
        if (_allowCustomDuration) {
            userMembershipDuration = _membershipDuration;
        } else {
            userMembershipDuration = ModuleConstants.DEFAULT_MEMBERSHIP_DURATION;
        }
        _member.benefitMultiplier = _benefitMultiplier;
        _member.membershipDuration = userMembershipDuration;
        _member.membershipStartTime = block.timestamp;
        _member.contribution = normalizedContributionBeforeFee;
        _member.claimAddAmount = claimAddAmount;
        _member.totalServiceFee = feeAmount;
        _member.memberState = _memberState;
        _member.isKYCVerified = _isKYCVerified;
        _member.isRefunded = _isRefunded;
        emit TakasureEvents.OnMemberUpdated(
            _member.memberId,
            _memberWallet,
            _benefitMultiplier,
            normalizedContributionBeforeFee,
            feeAmount,
            userMembershipDuration,
            block.timestamp
        );
        return _member;
    }

    function _getBenefitMultiplierFromOracle(
        address _member
    ) internal returns (uint256 benefitMultiplier_) {
        string memory memberAddressToString = Strings.toHexString(uint256(uint160(_member)), 20);
        // First we check if there is already a request id for this member
        bytes32 requestId = bmConsumer.memberToRequestId(memberAddressToString);
        if (requestId == 0) {
            // If there is no request id, it means the member has no valid BM yet. So we make a new request
            string[] memory args = new string[](1);
            args[0] = memberAddressToString;
            bmConsumer.sendRequest(args);
        } else {
            // If there is a request id, we check if it was successful
            bool successRequest = bmConsumer.idToSuccessRequest(requestId);
            if (successRequest) {
                benefitMultiplier_ = bmConsumer.idToBenefitMultiplier(requestId);
            } else {
                // If failed we get the error and revert with it
                bytes memory errorResponse = bmConsumer.idToErrorResponse(requestId);
                revert KYCModule__BenefitMultiplierRequestFailed(errorResponse);
            }
        }
    }

    function _transferContribution(
        IERC20 _contributionToken,
        address _memberWallet,
        address _takasureReserve,
        uint256 _contributionAfterFee
    ) internal override {
        subscriptionModule.transferContributionAfterKyc(
            _contributionToken, 
            _memberWallet, 
            _takasureReserve, 
            _contributionAfterFee
        );
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(ModuleConstants.OPERATOR) {}
}
