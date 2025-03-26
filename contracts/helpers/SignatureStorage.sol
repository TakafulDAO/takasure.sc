// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

contract SignatureStorage is EIP712 {
    mapping(bytes signature => address signer) public signatureToSigner;
    mapping(bytes signature => bytes32 messageHash) public signatureToMessageHash;
}
