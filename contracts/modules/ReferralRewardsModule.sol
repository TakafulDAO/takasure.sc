// SPDX-License-Identifier: GPL-3.0-only

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {IKYCModule} from "contracts/interfaces/modules/IKYCModule.sol";
import {IReferralRewardsModule} from "contracts/interfaces/modules/IReferralRewardsModule.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ModuleImplementation} from "contracts/modules/moduleUtils/ModuleImplementation.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ModuleState} from "contracts/types/States.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";

pragma solidity 0.8.28;

contract ReferralRewardsModule is
    ModuleImplementation,
    IReferralRewardsModule,
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable
{
    bool public referralDiscountEnabled;

    mapping(address child => address parent) public childToParent;
    // used to pay rewards to parents, it will be cleared when the parent is rewarded
    mapping(address parent => mapping(address child => uint256 reward)) private pendingParentRewardsByChild;
    // used for historic tracking of rewards
    mapping(address parent => mapping(address child => uint256 reward)) public historicParentRewardsByChild;

    uint256 private constant DECIMAL_CORRECTION = 10_000;
    int256 private constant MAX_TIER = 4;
    int256 private constant A = -3_125;
    int256 private constant B = 30_500;
    int256 private constant C = -99_625;
    int256 private constant D = 112_250;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnReferralDiscountSwitched(bool enabled);
    event OnParentRewardedStatus(
        address indexed parent, uint256 indexed layer, address indexed child, uint256 reward, bool success
    );

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

    function setReferralDiscountState(bool referralDiscountState)
        external
        onlyRole(Roles.OPERATOR, address(addressManager))
    {
        // Module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled, address(this), addressManager.getProtocolAddressByName("MODULE_MANAGER").addr
        );

        referralDiscountEnabled = referralDiscountState;

        emit OnReferralDiscountSwitched(referralDiscountEnabled);
    }

    function calculateReferralRewards(
        uint256 contribution,
        uint256 couponAmount,
        address child,
        address parent,
        uint256 feeAmount
    )
        external
        nonReentrant
        onlyType(ProtocolAddressType.Module, address(addressManager))
        returns (uint256 newFeeAmount_, uint256 discount_, uint256 toReferralReserveAmount_)
    {
        // Module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled, address(this), addressManager.getProtocolAddressByName("MODULE_MANAGER").addr
        );

        if (referralDiscountEnabled) {
            toReferralReserveAmount_ = (contribution * ModuleConstants.REFERRAL_RESERVE) / 100;

            // TODO: KYCModule implementation on other PR
            IKYCModule kycModule = IKYCModule(addressManager.getProtocolAddressByName("KYC_MODULE").addr);

            if (parent != address(0) && kycModule.isKYCed(parent)) {
                discount_ = ((contribution - couponAmount) * ModuleConstants.REFERRAL_DISCOUNT_RATIO) / 100;
                childToParent[child] = parent;

                uint256 fee =
                    _parentRewards({_initialChildToCheck: child, _contribution: contribution, _currentFee: feeAmount});

                newFeeAmount_ = fee;
            } else {
                newFeeAmount_ = feeAmount - toReferralReserveAmount_;
            }
        }
    }

    /**
     * @notice This function rewards the parents of a given child address
     * @param child The child address whose parents will be rewarded
     */
    function rewardParents(address child)
        external
        nonReentrant
        onlyType(ProtocolAddressType.Module, address(addressManager))
    {
        // Module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled, address(this), addressManager.getProtocolAddressByName("MODULE_MANAGER").addr
        );

        address parent = childToParent[child];
        for (uint256 i; i < uint256(MAX_TIER); ++i) {
            if (parent == address(0)) break;
            uint256 layer = i + 1;
            uint256 parentReward = pendingParentRewardsByChild[parent][child];
            // Reset the rewards for this child
            pendingParentRewardsByChild[parent][child] = 0;
            IERC20 contributionToken = IERC20(addressManager.getProtocolAddressByName("CONTRIBUTION_TOKEN").addr);

            try contributionToken.transfer(parent, parentReward) {
                emit OnParentRewardedStatus(parent, layer, child, parentReward, true);
            } catch {
                pendingParentRewardsByChild[parent][child] = parentReward;
                emit OnParentRewardedStatus(parent, layer, child, parentReward, false);
            }
            // We update the parent address to check the next parent
            parent = childToParent[parent];
        }
    }

    function _parentRewards(address _initialChildToCheck, uint256 _contribution, uint256 _currentFee)
        internal
        returns (uint256)
    {
        address currentChildToCheck = _initialChildToCheck;
        uint256 parentRewardsAccumulated;

        // Loop through the parent chain
        for (int256 i; i < MAX_TIER; ++i) {
            // Parent To check
            address parentToCheck = childToParent[currentChildToCheck];

            // If we reach someone without a parent, we stop
            if (parentToCheck == address(0)) break;

            uint256 reward = (_contribution * _referralRewardRatioByLayer(i + 1)) / (100 * DECIMAL_CORRECTION);

            pendingParentRewardsByChild[parentToCheck][_initialChildToCheck] = reward;
            historicParentRewardsByChild[parentToCheck][_initialChildToCheck] += reward;

            // Total rewards accumulated through the parent chain
            parentRewardsAccumulated += (_contribution * _referralRewardRatioByLayer(i + 1))
                / (100 * DECIMAL_CORRECTION);

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
    function _referralRewardRatioByLayer(int256 _layer) internal pure virtual returns (uint256 referralRewardRatio_) {
        assembly {
            let layerSquare := mul(_layer, _layer) // x^2
            let layerCube := mul(_layer, layerSquare) // x^3

            // y = Ax^3 + Bx^2 + Cx + D
            referralRewardRatio_ := add(add(add(mul(A, layerCube), mul(B, layerSquare)), mul(C, _layer)), D)
        }
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(Roles.OPERATOR, address(addressManager))
    {}
}
