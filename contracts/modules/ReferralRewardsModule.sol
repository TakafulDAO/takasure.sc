// SPDX-License-Identifier: GPL-3.0-only

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";

import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ModuleState, ProtocolAddressType} from "contracts/types/TakasureTypes.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";

pragma solidity 0.8.28;

contract ReferralRewardsModule is TLDModuleImplementation, Initializable, UUPSUpgradeable {
    bool public referralDiscountEnabled;
    // uint256 public referralReserve;

    mapping(address child => address parent) public childToParent;
    mapping(address parent => mapping(address child => uint256 reward)) public parentRewardsByChild;
    mapping(address parent => mapping(uint256 layer => uint256 reward)) public parentRewardsByLayer;

    uint256 private constant DECIMAL_CORRECTION = 10_000;
    int256 private constant MAX_TIER = 4;
    int256 private constant A = -3_125;
    int256 private constant B = 30_500;
    int256 private constant C = -99_625;
    int256 private constant D = 112_250;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _addressManager, string calldata _moduleName) external initializer {
        __UUPSUpgradeable_init();

        addressManager = IAddressManager(_addressManager);
        moduleName = _moduleName;

        referralDiscountEnabled = true; // Enable referral discount by default
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the module state
     * @dev Only callable from the Module Manager
     */
    function setContractState(
        ModuleState newState
    ) external override onlyContract("MODULE_MANAGER", address(addressManager)) {
        moduleState = newState;
    }

    function calculateReferralRewards(
        uint256 contribution,
        uint256 couponAmount,
        address child,
        address parent,
        uint256 feeAmount
    ) external returns (uint256 newFeeAmount, uint256 discount, uint256 toReferralReserveAmount) {
        require(
            AddressAndStates._checkType(address(addressManager), ProtocolAddressType.Module),
            ModuleErrors.Module__NotAuthorizedCaller()
        );

        if (referralDiscountEnabled) {
            toReferralReserveAmount = (contribution * ModuleConstants.REFERRAL_RESERVE) / 100;

            if (parent != address(0)) {
                discount =
                    ((contribution - couponAmount) * ModuleConstants.REFERRAL_DISCOUNT_RATIO) /
                    100;
                childToParent[child] = parent;

                // IERC20 contributionToken = IERC20(
                //     addressManager.getProtocolAddressByName("CONTRIBUTION_TOKEN").addr
                // );

                uint256 fee = _parentRewards({
                    _initialChildToCheck: child,
                    _contribution: contribution,
                    // _currentReferralReserve: contributionToken.balanceOf(address(this)),
                    // _toReferralReserve: toReferralReserveAmount,
                    _currentFee: feeAmount
                });

                // toReferralReserveAmount = toReferralReserveAmount; // ! esta linea esta mal
                // referralReserve = newReferralReserve;
                newFeeAmount = fee;
            } else {
                // toReferralReserveAmount = toReferralReserveAmount;
                // referralReserve += toReferralReserve;
                newFeeAmount = feeAmount - toReferralReserveAmount;
            }
        }
    }

    function rewardParents(address child) external {
        require(
            AddressAndStates._checkType(address(addressManager), ProtocolAddressType.Module),
            ModuleErrors.Module__NotAuthorizedCaller()
        );

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

    function _parentRewards(
        address _initialChildToCheck,
        uint256 _contribution,
        uint256 _currentFee
    ) internal virtual returns (uint256) {
        address currentChildToCheck = _initialChildToCheck;
        uint256 parentRewardsAccumulated;

        // Loop through the parent chain
        for (int256 i; i < MAX_TIER; ++i) {
            // Parent To check
            address parentToCheck = childToParent[currentChildToCheck];

            // If we reach someone without a parent, we stop
            if (parentToCheck == address(0)) {
                break;
            }

            // reward per child
            parentRewardsByChild[parentToCheck][_initialChildToCheck] =
                (_contribution * _referralRewardRatioByLayer(i + 1)) /
                (100 * DECIMAL_CORRECTION);

            // reward per layer
            parentRewardsByLayer[parentToCheck][uint256(i + 1)] +=
                (_contribution * _referralRewardRatioByLayer(i + 1)) /
                (100 * DECIMAL_CORRECTION);

            // Total rewards accumulated through the parent chain
            parentRewardsAccumulated +=
                (_contribution * _referralRewardRatioByLayer(i + 1)) /
                (100 * DECIMAL_CORRECTION);

            // Update the current child to check, for the next iteration
            currentChildToCheck = childToParent[currentChildToCheck];
        }

        return _currentFee;
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
    ) internal pure virtual returns (uint256 referralRewardRatio_) {
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

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(Roles.OPERATOR, address(addressManager)) {}
}
