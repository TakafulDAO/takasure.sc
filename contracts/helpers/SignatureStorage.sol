// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";

contract SignatureStorage is EIP712 {
    mapping(bytes signature => address signer) public signatureToSigner;
    mapping(bytes signature => bytes32 messageHash) public signatureToMessageHash;

    error SignatureStorage__InvalidSigner();

    constructor() EIP712("TheLifeDAO", "1") {}

    function storeSignature(
        bytes calldata signature,
        bytes32 messageHash,
        address signer
    ) external {
        AddressAndStates._notZeroAddress(signer);
        require(
            _isValidSignature(signer, _hashTypedDataV4(messageHash), signature),
            SignatureStorage__InvalidSigner()
        );
        signatureToSigner[signature] = signer;
        signatureToMessageHash[signature] = messageHash;
    }

    function getMessageHash(bytes32 messageHash) external view returns (bytes32) {
        return _hashTypedDataV4(messageHash);
    }

    function _isValidSignature(
        address _signer,
        bytes32 _digest,
        bytes calldata _signature
    ) internal pure returns (bool) {
        (address actualSigner, , ) = ECDSA.tryRecover(_digest, _signature);
        return actualSigner == _signer;
    }
}
