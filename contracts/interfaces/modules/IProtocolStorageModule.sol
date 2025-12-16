// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {AssociationMember, BenefitMember} from "contracts/types/Members.sol";

interface IProtocolStorageModule {
    /*
    List of keys used in the protocol storage:
    - memberIdCounter (uint256): Counter to assign new member IDs
    */

    function createAssociationMember(AssociationMember memory member) external;
    function updateAssociationMember(AssociationMember memory member) external;
    function createBenefitMember(address benefit, BenefitMember memory member) external;
    function updateBenefitMember(address benefit, BenefitMember memory member) external;
    function setUintValue(string calldata key, uint256 value) external;
    function setIntValue(string calldata key, int256 value) external;
    function setAddressValue(string calldata key, address value) external;
    function setBoolValue(string calldata key, bool value) external;
    function setBytes32Value(string calldata key, bytes32 value) external;
    function setBytesValue(string calldata key, bytes calldata value) external;
    function setBytes32Value2D(string calldata key1, string calldata key2, bytes32 value) external;
    function getAssociationMember(address memberAddress) external view returns (AssociationMember memory);
    function getBenefitMember(address benefit, address memberAddress) external view returns (BenefitMember memory);

    function getUintValue(string calldata key) external view returns (uint256);
    function getIntValue(string calldata key) external view returns (int256);
    function getAddressValue(string calldata key) external view returns (address);
    function getBoolValue(string calldata key) external view returns (bool);
    function getBytes32Value(string calldata key) external view returns (bytes32);
    function getBytesValue(string calldata key) external view returns (bytes memory);
    function getBytes32Value2D(string calldata key1, string calldata key2) external view returns (bytes32);
}
