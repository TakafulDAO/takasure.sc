// SPDX-License-Identifier: GPL-3.0-only

import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {IKYCModule} from "contracts/interfaces/modules/IKYCModule.sol";
import {IReferralRewardsModule} from "contracts/interfaces/modules/IReferralRewardsModule.sol";

import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";
import {AssociationHooks} from "contracts/hooks/AssociationHooks.sol";
import {ReserveHooks} from "contracts/hooks/ReserveHooks.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {ModuleState, AssociationMember, Reserve, BenefitMember, BenefitMemberState} from "contracts/types/TakasureTypes.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";

pragma solidity 0.8.28;

contract BenefitModule is
    TLDModuleImplementation,
    AssociationHooks,
    ReserveHooks,
    Initializable,
    ReentrancyGuardTransientUpgradeable
{
    uint256 private transient normalizedContributionBeforeFee;
    uint256 private transient feeAmount;
    uint256 private transient contributionAfterFee;
    uint256 private transient discount;

    mapping(address member => bool) private isMemberCouponALPRedeemer;

    error BenefitModule__BenefitNotSupported();
    error BenefitModule__InvalidContribution();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _addressManager, string calldata _moduleName) external initializer {
        __ReentrancyGuardTransient_init();

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

    /**
     * @notice Called by backend to allow new members to apply to the benefit from the current module
     * @param memberWallet address of the member
     * @param contributionBeforeFee in six decimals
     * @param membershipDuration default 5 years
     * @param couponAmount in six decimals
     * @dev it reverts if the member is not KYCed
     * @dev it reverts if the contribution is out of bounds
     * @dev it reverts if the member is already active
     * @dev the contribution amount will be round down so the last four decimals will be zero. This means
     *      that the minimum contribution amount is 0.01 USDC
     */
    function joinBenefitOnBehalfOf(
        address memberWallet,
        uint256 contributionBeforeFee,
        uint256 membershipDuration,
        uint256 couponAmount
    ) external nonReentrant {
        // Check caller
        require(
            AddressAndStates._checkName(address(addressManager), "ROUTER") ||
                msg.sender == memberWallet,
            ModuleErrors.Module__NotAuthorizedCaller()
        );

        (Reserve memory reserve, address parentWallet) = _paySubscriptionChecksAndsettings(
            memberWallet,
            contributionBeforeFee,
            couponAmount
        );

        _join(
            reserve,
            memberWallet,
            parentWallet,
            contributionBeforeFee,
            membershipDuration,
            couponAmount
        );

        if (couponAmount > 0) {
            isMemberCouponALPRedeemer[memberWallet] = true;
            emit TakasureEvents.OnCouponRedeemed(memberWallet, couponAmount);
        }
    }

    function _join(
        Reserve memory _reserve,
        address _memberWallet,
        address _parentWallet,
        uint256 _contributionBeforeFee,
        uint256 _membershipDuration,
        uint256 _couponAmount
    ) internal {
        BenefitMember memory newBenefitMember = _getBenefitMembersValuesHook(
            ITakasureReserve(addressManager.getProtocolAddressByName("TAKASURE_RESERVE").addr),
            _memberWallet
        );

        require(
            newBenefitMember.memberState == BenefitMemberState.Inactive ||
                newBenefitMember.memberState == BenefitMemberState.Canceled,
            ModuleErrors.Module__WrongMemberState()
        );
        require(
            _contributionBeforeFee >= _reserve.minimumThreshold &&
                _contributionBeforeFee <= _reserve.maximumThreshold,
            BenefitModule__InvalidContribution()
        );

        uint256 memberId = ++_reserve.memberIdCounter;

        newBenefitMember = _createNewMember({
            _newMemberId: memberId,
            _drr: _reserve.dynamicReserveRatio,
            _membershipDuration: _membershipDuration, // From the input
            _memberWallet: _memberWallet, // The member wallet
            _parentWallet: _parentWallet, // The parent wallet
            _memberState: BenefitMemberState.Inactive // Set to inactive until the KYC is verified
        });

        IReferralRewardsModule referralRewardsModule = IReferralRewardsModule(
            addressManager.getProtocolAddressByName("REFERRAL_REWARDS_MODULE").addr
        );

        (feeAmount, discount) = referralRewardsModule.calculateReferralRewards({
            contribution: normalizedContributionBeforeFee,
            couponAmount: _couponAmount,
            child: _memberWallet,
            parent: _parentWallet,
            feeAmount: feeAmount
        });

        referralRewardsModule.rewardParents({child: _memberWallet});

        newBenefitMember.discount = discount;

        // ITakasureReserve takasureReserve = ITakasureReserve(
        //     addressManager.getProtocolAddressByName("TAKASURE_RESERVE").addr
        // );

        // // The member will pay the contribution, but will remain inactive until the KYC is verified
        // // This means the proformas wont be updated, the amounts wont be added to the reserves,
        // // the cash flow mappings wont change, the DRR and BMA wont be updated, the tokens wont be minted
        // _transferContributionToModule({_memberWallet: _memberWallet, _couponAmount: _couponAmount, _takasureReserve: takasureReserve});
        // _setNewReserveAndMemberValuesHook(takasureReserve, _reserve, _newMember);
    }

    function _createNewMember(
        uint256 _newMemberId,
        uint256 _drr,
        uint256 _membershipDuration,
        address _memberWallet,
        address _parentWallet,
        BenefitMemberState _memberState
    ) internal returns (BenefitMember memory) {
        uint256 claimAddAmount = ((normalizedContributionBeforeFee - feeAmount) * (100 - _drr)) /
            100;

        BenefitMember memory newMember = BenefitMember({
            memberId: _newMemberId,
            benefitMultiplier: 0, // Placeholder, will be set after the KYC
            membershipDuration: _membershipDuration,
            membershipStartTime: block.timestamp,
            lastPaidYearStartDate: block.timestamp,
            contribution: normalizedContributionBeforeFee,
            discount: discount,
            claimAddAmount: claimAddAmount,
            totalContributions: normalizedContributionBeforeFee,
            totalServiceFee: feeAmount,
            creditsBalance: 0,
            wallet: _memberWallet,
            parent: _parentWallet,
            memberState: _memberState,
            memberSurplus: 0,
            lastEcr: 0,
            lastUcr: 0
        });

        emit TakasureEvents.OnMemberCreated(
            newMember.memberId,
            _memberWallet,
            normalizedContributionBeforeFee,
            feeAmount,
            _membershipDuration,
            block.timestamp
        );

        return newMember;
    }

    function _paySubscriptionChecksAndsettings(
        address _memberWallet,
        uint256 _contributionBeforeFee,
        uint256 _couponAmount
    ) internal returns (Reserve memory reserve_, address parentWallet_) {
        AddressAndStates._onlyModuleState(moduleState, ModuleState.Enabled);

        // Check if the coupon amount is valid
        require(_couponAmount <= _contributionBeforeFee, ModuleErrors.Module__InvalidCoupon());

        // Check if the member and the parent are KYCed
        IKYCModule kycModule = IKYCModule(
            addressManager.getProtocolAddressByName("KYC_MODULE").addr
        );

        require(kycModule.isKYCed(_memberWallet), ModuleErrors.Module__AddressNotKYCed());

        AssociationMember memory member = _getAssociationMembersValuesHook(
            addressManager,
            _memberWallet
        );

        if (_stringsEqual(moduleName, "LIFE_MODULE")) {
            require(!member.isLifeProtected, ModuleErrors.Module__AlreadyJoined());
        } else if (_stringsEqual(moduleName, "FAREWELL_MODULE")) {
            require(!member.isFarewellProtected, ModuleErrors.Module__AlreadyJoined());
        } else {
            revert BenefitModule__BenefitNotSupported();
        }

        reserve_ = _getReservesValuesHook(
            ITakasureReserve(addressManager.getProtocolAddressByName("TAKASURE_RESERVE").addr)
        );

        parentWallet_ = member.parent;

        _calculateAmountAndFees(_contributionBeforeFee, reserve_.serviceFee);
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

    function _stringsEqual(string memory _a, string memory _b) internal pure returns (bool) {
        return bytes(_a).length == bytes(_b).length && keccak256(bytes(_a)) == keccak256(bytes(_b));
    }
}
