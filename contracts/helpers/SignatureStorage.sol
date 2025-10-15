// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract SignatureStorage is EIP712, AccessControl {
    bytes32 public constant SIGNATURE_STORAGE_ROLE = keccak256("SIGNATURE_STORAGE_ROLE");

    mapping(bytes signature => address signer) public signatureToSigner;
    mapping(bytes signature => bytes32 messageHash) public signatureToMessageHash;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnSignatureStored(
        bytes indexed signature,
        address indexed signer,
        bytes32 indexed messageHash
    );

    error SignatureStorage__AlreadyStored();
    error SignatureStorage__InvalidSigner();

    constructor(address _signatureStorageRole) EIP712("TheLifeDAO", "1") {
        require(_signatureStorageRole != address(0));

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(SIGNATURE_STORAGE_ROLE, _signatureStorageRole);
    }

    /**
     * @notice Store the signature and the signer address
     * @param signature The signature to store, packed as bytes 65 bytes long
     * @param messageHash The hash of the message that was signed
     * @param signer The address of the signer
     * @dev Reverts if the signer is address zero
     * @dev Reverts if the signature is already stored
     * @dev The message hash is typed for EIP712
     */
    function storeSignature(
        bytes calldata signature,
        bytes32 messageHash,
        address signer
    ) external onlyRole(SIGNATURE_STORAGE_ROLE) {
        require(signatureToSigner[signature] == address(0), SignatureStorage__AlreadyStored());
        require(
            _isValidSignature(signer, _hashTypedDataV4(messageHash), signature),
            SignatureStorage__InvalidSigner()
        );

        signatureToSigner[signature] = signer;
        signatureToMessageHash[signature] = messageHash;

        emit OnSignatureStored(signature, signer, messageHash);
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
