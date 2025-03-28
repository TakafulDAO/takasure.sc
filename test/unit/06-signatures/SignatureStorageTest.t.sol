// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SignatureStorage} from "contracts/helpers/SignatureStorage.sol";

contract SignatureStorageTest is Test {
    SignatureStorage signatureStorage;
    address signer;
    uint256 signerPrivKey;
    bytes32 messageHash = keccak256("message");

    function setUp() public {
        signatureStorage = new SignatureStorage();
        (signer, signerPrivKey) = makeAddrAndKey("user");
    }

    function _signMessage(bytes32 _hash) internal view returns (bytes memory signature_) {
        bytes32 _digest = signatureStorage.getMessageHash(_hash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivKey, _digest);
        signature_ = abi.encodePacked(r, s, v);
    }

    function testStoreSignatureRevertsIfSignerIsAddressZero() public {
        bytes memory signature = _signMessage(messageHash);

        vm.expectRevert();
        signatureStorage.storeSignature(signature, messageHash, address(0));
    }

    function testStoreSignatureRevertsIfSignatureWontCorrespondToSigner() public {
        bytes memory signature = _signMessage(messageHash);

        address wrongSigner = makeAddr("wrongSigner");

        vm.expectRevert(SignatureStorage.SignatureStorage__InvalidSigner.selector);
        signatureStorage.storeSignature(signature, messageHash, wrongSigner);
    }

    function testStoreSignature() public {
        bytes memory signature = _signMessage(messageHash);

        signatureStorage.storeSignature(signature, messageHash, signer);

        assertEq(signatureStorage.signatureToSigner(signature), signer);
        assertEq(signatureStorage.signatureToMessageHash(signature), messageHash);
    }
}
