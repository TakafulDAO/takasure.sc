// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract SignatureStorage is EIP712 {
    mapping(bytes signature => address signer) public signatureToSigner;
    mapping(bytes signature => bytes32 messageHash) public signatureToMessageHash;

    error SignatureStorage__InvalidSigner();

    constructor() EIP712("TheLifeDAO", "1") {}

    function getMessageHash(bytes32 messageHash) external view returns (bytes32) {
        return _hashTypedDataV4(messageHash);
    }
}
