// SPDX-License-Identifier: GPL-3.0-only

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressManager} from "contracts/interfaces/IAddressManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";

import {ParentRewards} from "contracts/helpers/payments/ParentRewards.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ModuleState} from "contracts/types/TakasureTypes.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";

pragma solidity 0.8.28;

contract ReferralRewardsModule is
    Initializable,
    UUPSUpgradeable,
    TLDModuleImplementation,
    ParentRewards
{
    IAddressManager private addressManager;
    ModuleState private moduleState;

    string public moduleName;

    bool public referralDiscountEnabled;
    uint256 public referralReserve;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _addressManager, string calldata _moduleName) external initializer {
        __UUPSUpgradeable_init();

        addressManager = IAddressManager(_addressManager);
        moduleName = _moduleName;
    }

    /**
     * @notice Set the module state
     * @dev Only callable from the Module Manager
     */
    function setContractState(
        ModuleState newState
    ) external override onlyContract("MODULE_MANAGER", address(addressManager)) {
        moduleState = newState;
    }

    function calculateReferralRewardsFromSubscriptions(
        uint256 contribution,
        uint256 couponAmount,
        address child,
        address parent,
        uint256 feeAmount
    ) external returns (uint256, uint256) {
        uint256 toReferralReserve;
        uint256 discount;
        uint256 newFeeAmount;

        if (referralDiscountEnabled) {
            toReferralReserve = (contribution * ModuleConstants.REFERRAL_RESERVE) / 100;
            if (parent != address(0)) {
                discount =
                    ((contribution - couponAmount) * ModuleConstants.REFERRAL_DISCOUNT_RATIO) /
                    100;
                childToParent[child] = parent;
                (uint256 fee, uint256 newReferralReserve) = _parentRewards({
                    _initialChildToCheck: child,
                    _contribution: contribution,
                    _currentReferralReserve: referralReserve,
                    _toReferralReserve: toReferralReserve,
                    _currentFee: feeAmount
                });

                referralReserve = newReferralReserve;
                newFeeAmount = fee;
            } else {
                referralReserve += toReferralReserve;
                newFeeAmount = feeAmount;
            }
        }

        return (newFeeAmount, discount);
    }

    function rewardParentsFromSubscriptions(address child) external {
        address parent = childToParent[child];
        for (uint256 i; i < uint256(MAX_TIER); ++i) {
            if (parent == address(0)) break;
            uint256 layer = i + 1;
            uint256 parentReward = parentRewardsByChild[parent][child];
            // Reset the rewards for this child
            parentRewardsByChild[parent][child] = 0;
            IERC20 contributionToken = IERC20(
                addressManager.getProtocolAddressByName("CONTRIBUTION_TOKEN").addr
            );

            try contributionToken.transfer(parent, parentReward) {
                emit TakasureEvents.OnParentRewarded(parent, layer, child, parentReward);
            } catch {
                parentRewardsByChild[parent][child] = parentReward;
                emit TakasureEvents.OnParentRewardTransferFailed(
                    parent,
                    layer,
                    child,
                    parentReward
                );
            }
            // We update the parent address to check the next parent
            parent = childToParent[parent];
        }
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(Roles.OPERATOR, address(addressManager)) {}
}
