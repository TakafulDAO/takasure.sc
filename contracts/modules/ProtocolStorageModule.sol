// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ModuleImplementation} from "contracts/modules/moduleUtils/ModuleImplementation.sol";

import {ProtocolAddressType, AssociationMember} from "contracts/types/TakasureTypes.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";

contract ProtocolStorageModule is ModuleImplementation, Initializable, UUPSUpgradeable {
    // Association members related
    mapping(address member => AssociationMember) private members;

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

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event OnUintValueSet(bytes32 indexed key, uint256 value);
    event OnIntValueSet(bytes32 indexed key, int256 value);
    event OnAddressValueSet(bytes32 indexed key, address value);
    event OnBoolValueSet(bytes32 indexed key, bool value);
    event OnBytes32ValueSet(bytes32 indexed key, bytes32 value);
    event OnBytesValueSet(bytes32 indexed key, bytes value);
    event OnBytes32Value2DSet(bytes32 indexed key1, bytes32 indexed key2, bytes32 value);

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _addressManagerAddress,
        string calldata _moduleName
    ) external initializer {
        AddressAndStates._notZeroAddress(_addressManagerAddress);
        __UUPSUpgradeable_init();

        addressManager = IAddressManager(_addressManagerAddress);
        moduleName = _moduleName;
    }

    modifier onlyProtocolOrModule() {
        require(
            addressManager.hasType(ProtocolAddressType.Protocol, msg.sender) ||
                addressManager.hasType(ProtocolAddressType.Module, msg.sender),
            ModuleErrors.Module__NotAuthorizedCaller()
        );
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    function createMember(AssociationMember memory member) external onlyProtocolOrModule {
        members[member.wallet] = member;
    }

    function setUintValue(string calldata key, uint256 value) external onlyProtocolOrModule {
        bytes32 hashedKey = _hashKey(key);
        uintStorage[hashedKey] = value;
        emit OnUintValueSet(hashedKey, value);
    }

    function setIntValue(string calldata key, int256 value) external onlyProtocolOrModule {
        bytes32 hashedKey = _hashKey(key);
        intStorage[hashedKey] = value;
        emit OnIntValueSet(hashedKey, value);
    }

    function setAddressValue(string calldata key, address value) external onlyProtocolOrModule {
        bytes32 hashedKey = _hashKey(key);
        addressStorage[hashedKey] = value;
        emit OnAddressValueSet(hashedKey, value);
    }

    function setBoolValue(string calldata key, bool value) external onlyProtocolOrModule {
        bytes32 hashedKey = _hashKey(key);
        boolStorage[hashedKey] = value;
        emit OnBoolValueSet(hashedKey, value);
    }

    function setBytes32Value(string calldata key, bytes32 value) external onlyProtocolOrModule {
        bytes32 hashedKey = _hashKey(key);
        bytes32Storage[hashedKey] = value;
        emit OnBytes32ValueSet(hashedKey, value);
    }

    function setBytesValue(
        string calldata key,
        bytes calldata value
    ) external onlyProtocolOrModule {
        bytes32 hashedKey = _hashKey(key);
        bytesStorage[hashedKey] = value;
        emit OnBytesValueSet(hashedKey, value);
    }

    function setBytes32Value2D(
        string calldata key1,
        string calldata key2,
        bytes32 value
    ) external onlyProtocolOrModule {
        bytes32 hashedKey1 = _hashKey(key1);
        bytes32 hashedKey2 = _hashKey(key2);
        bytes32Storage2D[hashedKey1][hashedKey2] = value;
        emit OnBytes32Value2DSet(hashedKey1, hashedKey2, value);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function getMember(address memberAddress) external view returns (AssociationMember memory) {
        return members[memberAddress];
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

    function getBytes32Value2D(
        string calldata key1,
        string calldata key2
    ) external view returns (bytes32) {
        return bytes32Storage2D[_hashKey(key1)][_hashKey(key2)];
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Helper function to hash variable names to be used as keys in the storage mappings
     */
    function _hashKey(string memory variableName) internal pure returns (bytes32) {
        return keccak256(abi.encode(variableName));
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(Roles.OPERATOR, address(addressManager)) {}
}
