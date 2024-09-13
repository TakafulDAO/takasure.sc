//SPDX-License-Identifier: GPL-3.0

/**
 * @title TakasureReserve
 * @author Maikel Ordaz
 * @notice This contract will hold all the reserve values and the members data as well as balances
 * @dev Modules will be able to interact with this contract to update the reserve values and the members data
 * @dev Upgradeable contract with UUPS pattern
 */

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {TSToken} from "contracts/token/TSToken.sol";

import {NewReserve, Member} from "contracts/types/TakasureTypes.sol";
import {ReserveMathLib} from "contracts/libraries/ReserveMathLib.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {TakasureErrors} from "contracts/libraries/TakasureErrors.sol";

pragma solidity 0.8.25;

contract TakasureReserve is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    NewReserve private reserve;

    address public bmConsumer;
    address public kycProvider;
    address public feeClaimAddress;
    address public takadaoOperator;
    address private pauseGuardian;
    address private joinModuleContract;
    address private memberModuleContract;
    address private claimModuleContract;

    bytes32 private constant TAKADAO_OPERATOR = keccak256("TAKADAO_OPERATOR");
    bytes32 private constant DAO_MULTISIG = keccak256("DAO_MULTISIG");
    bytes32 private constant PAUSE_GUARDIAN = keccak256("PAUSE_GUARDIAN");
    bytes32 private constant JOIN_MODULE_CONTRACT = keccak256("JOIN_MODULE_CONTRACT");
    bytes32 private constant MEMBERS_MODULE_CONTRACT = keccak256("MEMBERS_MODULE_CONTRACT");
    bytes32 private constant CLAIM_MODULE_CONTRACT = keccak256("CLAIM_MODULE_CONTRACT");

    mapping(address member => Member) private members;
    mapping(uint256 memberIdCounter => address memberWallet) private idToMemberWallet;

    modifier notZeroAddress(address _address) {
        if (_address == address(0)) {
            revert TakasureErrors.TakasurePool__ZeroAddress();
        }
        _;
    }

    modifier onlyDaoOrTakadao() {
        if (!hasRole(TAKADAO_OPERATOR, msg.sender) && !hasRole(DAO_MULTISIG, msg.sender))
            revert TakasureErrors.OnlyDaoOrTakadao();
        _;
    }

    modifier onlyModuleContract() {
        if (
            !hasRole(JOIN_MODULE_CONTRACT, msg.sender) &&
            !hasRole(MEMBERS_MODULE_CONTRACT, msg.sender) &&
            !hasRole(CLAIM_MODULE_CONTRACT, msg.sender)
        ) revert TakasureErrors.OnlyModuleContract();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param _contributionToken default USDC
     * @param _feeClaimAddress address allowed to claim the service fee
     * @param _daoOperator address allowed to manage the DAO
     * @dev it reverts if any of the addresses is zero
     */
    function initialize(
        address _contributionToken,
        address _feeClaimAddress,
        address _daoOperator,
        address _takadaoOperator,
        address _kycProvider,
        address _pauseGuardian,
        address _tokenAdmin,
        string memory _tokenName,
        string memory _tokenSymbol
    ) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _daoOperator);
        _grantRole(TAKADAO_OPERATOR, _takadaoOperator);
        _grantRole(DAO_MULTISIG, _daoOperator);
        _grantRole(PAUSE_GUARDIAN, _pauseGuardian);

        takadaoOperator = _takadaoOperator;
        kycProvider = _kycProvider;
        feeClaimAddress = _feeClaimAddress;
        pauseGuardian = _pauseGuardian;

        TSToken daoToken = new TSToken(_tokenAdmin, _tokenName, _tokenSymbol);

        reserve.serviceFee = 22; // 22% of the contribution amount. Default
        reserve.bmaFundReserveShare = 70; // 70% Default
        reserve.fundMarketExpendsAddShare = 20; // 20% Default
        reserve.riskMultiplier = 2; // 2% Default
        reserve.isOptimizerEnabled = true; // Default
        reserve.daoToken = address(daoToken);
        reserve.contributionToken = _contributionToken;
        reserve.minimumThreshold = 25e6; // 25 USDC // 6 decimals
        reserve.maximumThreshold = 250e6; // 250 USDC // 6 decimals
        reserve.initialReserveRatio = 40; // 40% Default
        reserve.dynamicReserveRatio = 40; // Default
        reserve.benefitMultiplierAdjuster = 100; // 100% Default

        emit TakasureEvents.OnInitialReserveValues(
            reserve.initialReserveRatio,
            reserve.dynamicReserveRatio,
            reserve.benefitMultiplierAdjuster,
            reserve.serviceFee,
            reserve.bmaFundReserveShare,
            reserve.isOptimizerEnabled,
            reserve.contributionToken,
            reserve.daoToken
        );
    }

    function pause() external onlyRole(PAUSE_GUARDIAN) {
        _pause();
    }

    function unpause() external onlyRole(PAUSE_GUARDIAN) {
        _unpause();
    }

    function setMemberValuesFromModule(
        Member memory newMember
    ) external whenNotPaused onlyModuleContract {
        members[newMember.wallet] = newMember;
        idToMemberWallet[newMember.memberId] = newMember.wallet;
    }

    function setReserveValuesFromModule(
        NewReserve memory newReserve
    ) external whenNotPaused onlyModuleContract {
        reserve = newReserve;
    }

    function setNewJoinModuleContract(
        address newJoinModuleContract
    ) external onlyDaoOrTakadao notZeroAddress(newJoinModuleContract) {
        address oldJoinModuleContract = joinModuleContract;

        if (oldJoinModuleContract == newJoinModuleContract)
            revert TakasureErrors.TakasurePool__SameModuleContract();

        if (oldJoinModuleContract != address(0))
            revokeRole(JOIN_MODULE_CONTRACT, oldJoinModuleContract);

        joinModuleContract = newJoinModuleContract;
        grantRole(JOIN_MODULE_CONTRACT, newJoinModuleContract);

        emit TakasureEvents.OnNewJoinModuleContract(oldJoinModuleContract, newJoinModuleContract);
    }

    function setNewMembersModuleContract(
        address newMembersModuleContract
    ) external onlyDaoOrTakadao notZeroAddress(newMembersModuleContract) {
        address oldMemberModuleContract = memberModuleContract;

        if (oldMemberModuleContract == newMembersModuleContract)
            revert TakasureErrors.TakasurePool__SameModuleContract();

        if (oldMemberModuleContract != address(0))
            revokeRole(MEMBERS_MODULE_CONTRACT, oldMemberModuleContract);

        memberModuleContract = newMembersModuleContract;
        grantRole(MEMBERS_MODULE_CONTRACT, newMembersModuleContract);

        emit TakasureEvents.OnNewMemberModuleContract(
            oldMemberModuleContract,
            newMembersModuleContract
        );
    }

    function setNewClaimModuleContract(
        address newClaimModuleContract
    ) external onlyDaoOrTakadao notZeroAddress(newClaimModuleContract) {
        address oldClaimModuleContract = claimModuleContract;

        if (oldClaimModuleContract == newClaimModuleContract)
            revert TakasureErrors.TakasurePool__SameModuleContract();

        if (oldClaimModuleContract != address(0))
            revokeRole(CLAIM_MODULE_CONTRACT, oldClaimModuleContract);

        claimModuleContract = newClaimModuleContract;
        grantRole(CLAIM_MODULE_CONTRACT, newClaimModuleContract);

        emit TakasureEvents.OnNewClaimModuleContract(
            oldClaimModuleContract,
            newClaimModuleContract
        );
    }

    function setNewServiceFee(uint8 newServiceFee) external onlyRole(TAKADAO_OPERATOR) {
        if (newServiceFee > 35) {
            revert TakasureErrors.TakasurePool__WrongServiceFee();
        }
        reserve.serviceFee = newServiceFee;

        emit TakasureEvents.OnServiceFeeChanged(newServiceFee);
    }

    function setNewFundMarketExpendsShare(
        uint8 newFundMarketExpendsAddShare
    ) external onlyRole(DAO_MULTISIG) {
        if (newFundMarketExpendsAddShare > 35) {
            revert TakasureErrors.TakasurePool__WrongFundMarketExpendsShare();
        }
        uint8 oldFundMarketExpendsAddShare = reserve.fundMarketExpendsAddShare;
        reserve.fundMarketExpendsAddShare = newFundMarketExpendsAddShare;

        emit TakasureEvents.OnNewMarketExpendsFundReserveAddShare(
            newFundMarketExpendsAddShare,
            oldFundMarketExpendsAddShare
        );
    }

    function setAllowCustomDuration(bool _allowCustomDuration) external onlyRole(DAO_MULTISIG) {
        reserve.allowCustomDuration = _allowCustomDuration;

        emit TakasureEvents.OnAllowCustomDuration(_allowCustomDuration);
    }

    function setNewMinimumThreshold(uint256 newMinimumThreshold) external onlyRole(DAO_MULTISIG) {
        reserve.minimumThreshold = newMinimumThreshold;

        emit TakasureEvents.OnNewMinimumThreshold(newMinimumThreshold);
    }

    function setNewMaximumThreshold(uint256 newMaximumThreshold) external onlyRole(DAO_MULTISIG) {
        reserve.maximumThreshold = newMaximumThreshold;

        emit TakasureEvents.OnNewMaximumThreshold(newMaximumThreshold);
    }

    function setNewContributionToken(
        address newContributionToken
    ) external onlyRole(DAO_MULTISIG) notZeroAddress(newContributionToken) {
        address oldContributionToken = reserve.contributionToken;
        reserve.contributionToken = newContributionToken;

        emit TakasureEvents.OnNewContributionToken(oldContributionToken, newContributionToken);
    }

    function setNewFeeClaimAddress(
        address newFeeClaimAddress
    ) external onlyRole(TAKADAO_OPERATOR) notZeroAddress(newFeeClaimAddress) {
        address oldFeeClaimAddress = feeClaimAddress;
        feeClaimAddress = newFeeClaimAddress;

        emit TakasureEvents.OnNewFeeClaimAddress(oldFeeClaimAddress, newFeeClaimAddress);
    }

    function setNewBenefitMultiplierConsumerAddress(
        address newBenefitMultiplierConsumerAddress
    ) external onlyDaoOrTakadao notZeroAddress(newBenefitMultiplierConsumerAddress) {
        address oldBenefitMultiplierConsumer = address(bmConsumer);
        bmConsumer = newBenefitMultiplierConsumerAddress;

        emit TakasureEvents.OnBenefitMultiplierConsumerChanged(
            newBenefitMultiplierConsumerAddress,
            oldBenefitMultiplierConsumer
        );
    }

    function setNewKycProviderAddress(
        address newKycProviderAddress
    ) external onlyRole(DAO_MULTISIG) {
        address oldKycProvider = kycProvider;
        kycProvider = newKycProviderAddress;

        emit TakasureEvents.OnNewKycProviderAddress(oldKycProvider, newKycProviderAddress);
    }

    function setNewPauseGuardianAddress(address newPauseGuardianAddress) external onlyDaoOrTakadao {
        address oldPauseGuardian = pauseGuardian;
        pauseGuardian = newPauseGuardianAddress;

        _grantRole(PAUSE_GUARDIAN, newPauseGuardianAddress);
        _revokeRole(PAUSE_GUARDIAN, oldPauseGuardian);

        emit TakasureEvents.OnNewPauseGuardianAddress(oldPauseGuardian, newPauseGuardianAddress);
    }

    function getReserveValues() external view returns (NewReserve memory) {
        return reserve;
    }

    function getMemberFromAddress(address member) external view returns (Member memory) {
        return members[member];
    }

    function getMemberFromId(uint256 memberId) external view returns (address) {
        return idToMemberWallet[memberId];
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DAO_MULTISIG) {}
}
