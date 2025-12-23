// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {IKYCModule} from "contracts/interfaces/modules/IKYCModule.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ModuleImplementation} from "contracts/modules/moduleUtils/ModuleImplementation.sol";

import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {ModuleState, AssociationMemberState} from "contracts/types/States.sol";
import {AssociationMember, BenefitMember} from "contracts/types/Members.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";

contract MainStorageModule is ModuleImplementation, Initializable, UUPSUpgradeable {
    // Association members related
    mapping(address member => AssociationMember) private members;
    // Benefit members related
    mapping(address benefit => mapping(address member => BenefitMember)) private benefitMembers;
    mapping(address benefit => uint256) private benefitMemberIdCounters;

    // Generic values
    // All mappings are `variable_name` => `variable_value` one for each type
    mapping(bytes32 => uint256) internal uintStorage;
    mapping(bytes32 => int256) internal intStorage;
    mapping(bytes32 => address) internal addressStorage;
    mapping(bytes32 => bool) internal boolStorage;
    mapping(bytes32 => bytes32) internal bytes32Storage;
    mapping(bytes32 => bytes) internal bytesStorage;

    // A 2D mapping to store new variables in the future without needing to redeploy
    mapping(bytes32 => mapping(bytes32 => bytes32)) internal bytes32Storage2D;

    /*
    List of keys used in the protocol storage:
    - memberIdCounter (uint256): Counter to assign new member IDs
    - allowUserInitiatedCalls (bool): Flag to allow or disallow users to call paySubscription in SubscriptionModule
    - benefitFee (uint256): Fee in basis points
    - ... (other keys can be added as needed)
    */

    uint256 public constant MAX_FEE = 35; // 35%

    // Frequently read/write keys can be added as constants here for gas efficiency
    bytes32 internal constant MEMBER_ID_COUNTER = 0x2b5d5fdc61aab63670213f6da13321480a5157a1cc7f8263f9c36641ff091666; // keccak256(abi.encode("memberIdCounter"))

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnNewAssociationMember(
        uint256 indexed memberId,
        address indexed memberWallet,
        address indexed parentWallet,
        uint256 couponAmountRedeemed
    );
    event OnAssociationMemberUpdated(
        uint256 indexed memberId, address indexed memberWallet, uint256 couponAmountRedeemed
    );
    event OnUintValueSet(bytes32 indexed key, uint256 value);
    event OnIntValueSet(bytes32 indexed key, int256 value);
    event OnAddressValueSet(bytes32 indexed key, address value);
    event OnBoolValueSet(bytes32 indexed key, bool value);
    event OnBytes32ValueSet(bytes32 indexed key, bytes32 value);
    event OnBytesValueSet(bytes32 indexed key, bytes value);
    event OnBytes32Value2DSet(bytes32 indexed key1, bytes32 indexed key2, bytes32 value);

    error MainStorageModule__FeeExceedsMaximum(bytes32 keyHash, uint256 attemptedFee, uint256 maxFee);

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _addressManagerAddress, string calldata _moduleName) external initializer {
        AddressAndStates._notZeroAddress(_addressManagerAddress);
        __UUPSUpgradeable_init();

        addressManager = IAddressManager(_addressManagerAddress);
        moduleName = _moduleName;
    }

    modifier onlyProtocolsAddresses() {
        require(
            addressManager.hasType(ProtocolAddressType.Admin, msg.sender)
                || addressManager.hasType(ProtocolAddressType.Benefit, msg.sender)
                || addressManager.hasType(ProtocolAddressType.Module, msg.sender)
                || addressManager.hasType(ProtocolAddressType.Protocol, msg.sender),
            ModuleErrors.Module__NotAuthorizedCaller()
        );
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    function createAssociationMember(AssociationMember memory member)
        external
        onlyContract("MODULE__SUBSCRIPTION", address(addressManager))
    {
        // The module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled, address(this), addressManager.getProtocolAddressByName("PROTOCOL__MODULE_MANAGER").addr
        );

        _associationMemberProfileChecks(member, false);

        // Get the current member ID counter
        uint256 memberIdCounter = uintStorage[MEMBER_ID_COUNTER];
        member.memberId = memberIdCounter;

        members[member.wallet] = member;

        // Increment the member ID counter for the next member
        unchecked {
            ++memberIdCounter;
        }
        uintStorage[MEMBER_ID_COUNTER] = memberIdCounter;

        emit OnNewAssociationMember(member.memberId, member.wallet, member.parent, member.couponAmountRedeemed);
    }

    function updateAssociationMember(AssociationMember memory member) external {
        // The module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled, address(this), addressManager.getProtocolAddressByName("PROTOCOL__MODULE_MANAGER").addr
        );
        require(
            addressManager.hasName("MODULE__SUBSCRIPTION", msg.sender)
                || addressManager.hasName("MODULE__MANAGE_SUBSCRIPTION", msg.sender),
            ModuleErrors.Module__NotAuthorizedCaller()
        );
        _associationMemberProfileChecks(member, true);

        // Ensure the memberId is preserved
        member.memberId = members[member.wallet].memberId;
        members[member.wallet] = member;

        emit OnAssociationMemberUpdated(member.memberId, member.wallet, member.couponAmountRedeemed);
    }

    // TODO: Implement this when the benefit module is ready
    function createBenefitMember() external view {
        // The module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled, address(this), addressManager.getProtocolAddressByName("PROTOCOL__MODULE_MANAGER").addr
        );
    }

    // Todo: This might change on benefit modules implementation
    function updateBenefitMember(address benefit, BenefitMember memory member) external {
        // The module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled, address(this), addressManager.getProtocolAddressByName("PROTOCOL__MODULE_MANAGER").addr
        );
        require(
            addressManager.hasType(ProtocolAddressType.Benefit, msg.sender)
                || addressManager.hasName("MODULE__MANAGE_SUBSCRIPTION", msg.sender),
            ModuleErrors.Module__NotAuthorizedCaller()
        );

        require(member.wallet != address(0) && member.wallet != member.parent, ModuleErrors.Module__InvalidAddress());

        // Ensure the memberId is preserved
        member.memberId = benefitMembers[benefit][member.wallet].memberId;
        benefitMembers[benefit][member.wallet] = member;
    }

    function setUintValue(string calldata key, uint256 value) external onlyProtocolsAddresses {
        // The module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled, address(this), addressManager.getProtocolAddressByName("PROTOCOL__MODULE_MANAGER").addr
        );
        bytes32 hashedKey = _hashKey(key);

        // If the key is a fee, ensure it does not exceed the maximum allowed
        if (_hasFeeSuffix(key)) {
            require(value <= MAX_FEE, MainStorageModule__FeeExceedsMaximum(hashedKey, value, MAX_FEE));
        }

        uintStorage[hashedKey] = value;
        emit OnUintValueSet(hashedKey, value);
    }

    function setIntValue(string calldata key, int256 value) external onlyProtocolsAddresses {
        // The module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled, address(this), addressManager.getProtocolAddressByName("PROTOCOL__MODULE_MANAGER").addr
        );
        bytes32 hashedKey = _hashKey(key);
        intStorage[hashedKey] = value;
        emit OnIntValueSet(hashedKey, value);
    }

    function setAddressValue(string calldata key, address value) external onlyProtocolsAddresses {
        // The module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled, address(this), addressManager.getProtocolAddressByName("PROTOCOL__MODULE_MANAGER").addr
        );
        bytes32 hashedKey = _hashKey(key);
        addressStorage[hashedKey] = value;
        emit OnAddressValueSet(hashedKey, value);
    }

    function setBoolValue(string calldata key, bool value) external onlyProtocolsAddresses {
        // The module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled, address(this), addressManager.getProtocolAddressByName("PROTOCOL__MODULE_MANAGER").addr
        );
        bytes32 hashedKey = _hashKey(key);
        boolStorage[hashedKey] = value;
        emit OnBoolValueSet(hashedKey, value);
    }

    function setBytes32Value(string calldata key, bytes32 value) external onlyProtocolsAddresses {
        // The module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled, address(this), addressManager.getProtocolAddressByName("PROTOCOL__MODULE_MANAGER").addr
        );
        bytes32 hashedKey = _hashKey(key);
        bytes32Storage[hashedKey] = value;
        emit OnBytes32ValueSet(hashedKey, value);
    }

    function setBytesValue(string calldata key, bytes calldata value) external onlyProtocolsAddresses {
        // The module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled, address(this), addressManager.getProtocolAddressByName("PROTOCOL__MODULE_MANAGER").addr
        );
        bytes32 hashedKey = _hashKey(key);
        bytesStorage[hashedKey] = value;
        emit OnBytesValueSet(hashedKey, value);
    }

    function setBytes32Value2D(string calldata key1, string calldata key2, bytes32 value)
        external
        onlyProtocolsAddresses
    {
        // The module must be enabled
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled, address(this), addressManager.getProtocolAddressByName("PROTOCOL__MODULE_MANAGER").addr
        );
        bytes32 hashedKey1 = _hashKey(key1);
        bytes32 hashedKey2 = _hashKey(key2);
        bytes32Storage2D[hashedKey1][hashedKey2] = value;
        emit OnBytes32Value2DSet(hashedKey1, hashedKey2, value);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function getAssociationMember(address memberAddress) external view returns (AssociationMember memory) {
        return members[memberAddress];
    }

    function getBenefitMember(address benefit, address memberAddress) external view returns (BenefitMember memory) {
        return benefitMembers[benefit][memberAddress];
    }

    function getUintValue(string calldata key) external view returns (uint256) {
        return uintStorage[_hashKey(key)];
    }

    function getIntValue(string calldata key) external view returns (int256) {
        return intStorage[_hashKey(key)];
    }

    function getAddressValue(string calldata key) external view returns (address) {
        return addressStorage[_hashKey(key)];
    }

    function getBoolValue(string calldata key) external view returns (bool) {
        return boolStorage[_hashKey(key)];
    }

    function getBytes32Value(string calldata key) external view returns (bytes32) {
        return bytes32Storage[_hashKey(key)];
    }

    function getBytesValue(string calldata key) external view returns (bytes memory) {
        return bytesStorage[_hashKey(key)];
    }

    function getBytes32Value2D(string calldata key1, string calldata key2) external view returns (bytes32) {
        return bytes32Storage2D[_hashKey(key1)][_hashKey(key2)];
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _associationMemberProfileChecks(AssociationMember memory _member, bool isRejoin) internal view {
        if (isRejoin) {
            require(members[_member.wallet].wallet != address(0), ModuleErrors.Module__InvalidAddress());
        } else {
            require(members[_member.wallet].wallet == address(0), ModuleErrors.Module__AlreadyJoined());
        }

        require(_member.wallet != address(0) && _member.wallet != _member.parent, ModuleErrors.Module__InvalidAddress());

        // The user state must be inactive or canceled and not refunded
        require(
            (_member.memberState == AssociationMemberState.Inactive
                    || _member.memberState == AssociationMemberState.Canceled) && !_member.isRefunded,
            ModuleErrors.Module__WrongMemberState()
        );

        // If a parent wallet is provided, it must be KYCed
        if (_member.parent != address(0)) {
            address kycModule = addressManager.getProtocolAddressByName("MODULE__KYC").addr;
            // Check if the parent is KYCed
            require(IKYCModule(kycModule).isKYCed(_member.parent), ModuleErrors.Module__AddressNotKYCed());
        }

        // The membership start time can not be in the future
        require(_member.associateStartTime <= block.timestamp, ModuleErrors.Module__InvalidDate());
    }

    /**
     * @notice Helper function to hash variable names to be used as keys in the storage mappings
     */
    function _hashKey(string memory variableName) internal pure returns (bytes32) {
        return keccak256(abi.encode(variableName));
    }

    /**
     * @dev Checks if a key has fee suffix in its name
     */
    function _hasFeeSuffix(string calldata _key) internal pure returns (bool) {
        bytes calldata keyBytes = bytes(_key);
        uint256 len = keyBytes.length;

        return (len >= 4 && keyBytes[len - 4] == bytes1(0x5f) // _
                && keyBytes[len - 3] == bytes1(0x66) // f
                && keyBytes[len - 2] == bytes1(0x65) // e
                && keyBytes[len - 1] == bytes1(0x65)); // e
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(Roles.OPERATOR, address(addressManager))
    {}
}
