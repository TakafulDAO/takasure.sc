//SPDX-License-Identifier: GPL-3.0

/**
 * @title KYCModule
 * @author Maikel Ordaz
 * @notice This contract manage the KYC flow
 * @dev It will interact with the TakasureReserve contract to update the values. Only admin functions
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

    error KYCModule__NoContribution();
    error KYCModule__BenefitMultiplierRequestFailed(bytes errorResponse);
    error KYCModule__MemberAlreadyKYCed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _takasureReserveAddress,
        address _subscriptionModuleAddress
    ) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuardTransient_init();

        takasureReserve = ITakasureReserve(_takasureReserveAddress);
        bmConsumer = IBenefitMultiplierConsumer(takasureReserve.bmConsumer());
        subscriptionModule = ISubscriptionModule(_subscriptionModuleAddress);

        address takadaoOperator = takasureReserve.takadaoOperator();

        _grantRole(DEFAULT_ADMIN_ROLE, takadaoOperator);
        _grantRole(ModuleConstants.MODULE_MANAGER, takasureReserve.moduleManager());
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

        uint256 benefitMultiplier = _getBenefitMultiplierFromOracle(memberWallet);

        // We update the member values
        newMember.benefitMultiplier = benefitMultiplier;
        newMember.membershipStartTime = block.timestamp;
        newMember.memberState = MemberState.Active; // Active state as the user is already paid the contribution and KYCed
        newMember.isKYCVerified = true;

        // Then the everyting needed will be updated, proformas, reserves, cash flow,
        // DRR, BMA, tokens minted, no need to transfer the amounts as they are already paid
        uint256 mintedTokens;
        (reserve, mintedTokens) = _memberPaymentFlow({
            _contributionBeforeFee: newMember.contribution,
            _contributionAfterFee: newMember.contribution -
                ((newMember.contribution * reserve.serviceFee) / 100),
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
