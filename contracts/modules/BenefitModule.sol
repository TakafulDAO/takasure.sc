// SPDX-License-Identifier: GPL-3.0-only

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {IKYCModule} from "contracts/interfaces/modules/IKYCModule.sol";
import {IReferralRewardsModule} from "contracts/interfaces/modules/IReferralRewardsModule.sol";

import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";
import {AssociationHooks} from "contracts/hooks/AssociationHooks.sol";
import {ReserveHooks} from "contracts/hooks/ReserveHooks.sol";
import {MemberPaymentFlow} from "contracts/helpers/payments/MemberPaymentFlow.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {ModuleState, AssociationMember, Reserve, BenefitMember, BenefitMemberState} from "contracts/types/TakasureTypes.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract BenefitModule is
    TLDModuleImplementation,
    AssociationHooks,
    ReserveHooks,
    MemberPaymentFlow,
    Initializable,
    ReentrancyGuardTransientUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 private transient normalizedContributionBeforeFee;
    uint256 private transient feeAmount;
    uint256 private transient contributionAfterFee;
    uint256 private transient discount;

    mapping(address member => BenefitMember) private members;
    mapping(address member => bool) private isMemberCouponALPRedeemer;

    event OnMemberJoinedBenefit(
        string indexed benefitName,
        uint256 indexed memberId,
        address indexed member
    );

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
     * @param couponAmount amount of the coupon in six decimals
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
    ) external nonReentrant onlyRole(Roles.COUPON_REDEEMER, address(addressManager)) {
        // Check caller
        require(
            AddressAndStates._checkName(address(addressManager), "ROUTER") ||
                msg.sender == memberWallet,
            ModuleErrors.Module__NotAuthorizedCaller()
        );

        (
            Reserve memory reserve,
            address parentWallet,
            AssociationMember memory member
        ) = _paySubscriptionChecksAndsettings(memberWallet, contributionBeforeFee, couponAmount);

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

        _setBenefitInAssociation(member);
    }

    function _paySubscriptionChecksAndsettings(
        address _memberWallet,
        uint256 _contributionBeforeFee,
        uint256 _couponAmount
    )
        internal
        returns (Reserve memory reserve_, address parentWallet_, AssociationMember memory member_)
    {
        AddressAndStates._onlyModuleState(moduleState, ModuleState.Enabled);

        // Check if the coupon amount is valid
        require(_couponAmount <= _contributionBeforeFee, ModuleErrors.Module__InvalidCoupon());

        // Check if the member and the parent are KYCed
        IKYCModule kycModule = IKYCModule(
            addressManager.getProtocolAddressByName("KYC_MODULE").addr
        );

        require(kycModule.isKYCed(_memberWallet), ModuleErrors.Module__AddressNotKYCed());

        member_ = _getAssociationMembersValuesHook(addressManager, _memberWallet);

        if (_stringsEqual(moduleName, "LIFE_MODULE")) {
            require(!member_.isLifeProtected, ModuleErrors.Module__AlreadyJoined());
        } else if (_stringsEqual(moduleName, "FAREWELL_MODULE")) {
            require(!member_.isFarewellProtected, ModuleErrors.Module__AlreadyJoined());
        } else {
            revert BenefitModule__BenefitNotSupported();
        }

        reserve_ = _getReservesValuesHook(
            ITakasureReserve(addressManager.getProtocolAddressByName("TAKASURE_RESERVE").addr)
        );

        parentWallet_ = member_.parent;

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
            _parentWallet: _parentWallet // The parent wallet
        });

        IReferralRewardsModule referralRewardsModule = IReferralRewardsModule(
            addressManager.getProtocolAddressByName("REFERRAL_REWARDS_MODULE").addr
        );

        uint256 toReferralReserveAmount;
        (feeAmount, discount, toReferralReserveAmount) = referralRewardsModule
            .calculateReferralRewards({
                contribution: normalizedContributionBeforeFee,
                couponAmount: _couponAmount,
                child: _memberWallet,
                parent: _parentWallet,
                feeAmount: feeAmount
            });

        // The member will pay the contribution, but will remain inactive until the BM is setted
        // This means the proformas wont be updated, the amounts wont be added to the reserves,
        // the cash flow mappings wont change, the DRR and BMA wont be updated, the tokens wont be minted
        _transferContributionToModule({_memberWallet: _memberWallet, _couponAmount: _couponAmount});

        ITakasureReserve takasureReserve = ITakasureReserve(
            addressManager.getProtocolAddressByName("TAKASURE_RESERVE").addr
        );

        // We run the model algorithms to update the reserve values, proformas, cash flow,
        // DRR, BMA, tokens minted, no need to transfer the amounts as they are already paid
        uint256 credits_;

        (_reserve, credits_) = _memberPaymentFlow({
            _contributionBeforeFee: newBenefitMember.contribution,
            _contributionAfterFee: newBenefitMember.contribution -
                ((newBenefitMember.contribution * _reserve.serviceFee) / 100),
            _memberWallet: _memberWallet,
            _reserve: _reserve,
            _takasureReserve: takasureReserve
        });

        newBenefitMember.discount = discount;
        newBenefitMember.creditsBalance += credits_;

        // Store the member as part of this benefit
        members[_memberWallet] = newBenefitMember;

        // Reward the parents
        referralRewardsModule.rewardParents({child: _memberWallet});
        emit OnMemberJoinedBenefit(moduleName, newBenefitMember.memberId, _memberWallet);

        // Update the reserve with the new member
        _setNewReserveAndMemberValuesHook(takasureReserve, _reserve, newBenefitMember);
        takasureReserve.memberSurplus(newBenefitMember);
    }

    function _setBenefitInAssociation(AssociationMember memory _member) internal {
        // TODO: Maybe instead of this use a Enumerable set to be able to loop through the members? Maybe not needed because I can use this var only to check and loop through all in the reserve. CHECKKKKK
        if (_stringsEqual(moduleName, "LIFE_MODULE")) {
            _member.isLifeProtected = true;
        } else if (_stringsEqual(moduleName, "FAREWELL_MODULE")) {
            _member.isFarewellProtected = true;
        }
        _setAssociationMembersValuesHook(addressManager, _member);
    }

    function _createNewMember(
        uint256 _newMemberId,
        uint256 _drr,
        uint256 _membershipDuration,
        address _memberWallet,
        address _parentWallet
    ) internal returns (BenefitMember memory) {
        uint256 claimAddAmount = ((normalizedContributionBeforeFee - feeAmount) * (100 - _drr)) /
            100;

        BenefitMember memory newMember = BenefitMember({
            memberId: _newMemberId,
            benefitMultiplier: 0, // Placeholder, will be set after
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
            memberState: BenefitMemberState.Active,
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

    function _transferContributionToModule(address _memberWallet, uint256 _couponAmount) internal {
        ITakasureReserve takasureReserve = ITakasureReserve(
            addressManager.getProtocolAddressByName("TAKASURE_RESERVE").addr
        );

        IERC20 contributionToken = IERC20(takasureReserve.getReserveValues().contributionToken);
        uint256 _amountToTransferFromMember;

        if (_couponAmount > 0) {
            _amountToTransferFromMember = contributionAfterFee - discount - _couponAmount;
        } else {
            _amountToTransferFromMember = contributionAfterFee - discount;
        }

        // Store temporarily the contribution in this contract, this way will be available for refunds
        if (_amountToTransferFromMember > 0) {
            contributionToken.safeTransferFrom(
                _memberWallet,
                address(this),
                _amountToTransferFromMember
            );

            // Transfer the coupon amount to this contract
            if (_couponAmount > 0) {
                address couponPool = addressManager.getProtocolAddressByName("COUPON_POOL").addr;
                contributionToken.safeTransferFrom(couponPool, address(this), _couponAmount);
            }

            // Transfer the service fee to the fee claim address
            address feeClaimAddress = addressManager
                .getProtocolAddressByName("FEE_CLAIM_ADDRESS")
                .addr;

            contributionToken.safeTransferFrom(_memberWallet, feeClaimAddress, feeAmount);
        }
    }

    function _stringsEqual(string memory _a, string memory _b) internal pure returns (bool) {
        return bytes(_a).length == bytes(_b).length && keccak256(bytes(_a)) == keccak256(bytes(_b));
    }
}
