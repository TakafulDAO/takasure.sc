// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SignatureStorage} from "contracts/helpers/SignatureStorage.sol";

contract SignatureStorageTest is Test {
    SignatureStorage signatureStorage;
    address signatureStorageRole = makeAddr("signatureStorageRole");
    address signer;
    uint256 signerPrivKey;
    bytes32 messageHash = keccak256("message");

    event OnSignatureStored(
        bytes indexed signature,
        address indexed signer,
        bytes32 indexed messageHash
    );

    function setUp() public {
        signatureStorage = new SignatureStorage(signatureStorageRole);
        (signer, signerPrivKey) = makeAddrAndKey("user");
    }

    function _signMessage(bytes32 _hash) internal view returns (bytes memory signature_) {
        bytes32 _digest = signatureStorage.getMessageHash(_hash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivKey, _digest);
        signature_ = abi.encodePacked(r, s, v);
    }

    function testStoreSignatureRevertsIfCallerIsNotAuthorized() public {
        bytes memory signature = _signMessage(messageHash);

        vm.expectRevert();
        signatureStorage.storeSignature(signature, messageHash, signer);
    }

    function testStoreSignatureRevertsIfSignerIsAddressZero() public {
        bytes memory signature = _signMessage(messageHash);

        vm.prank(signatureStorageRole);
        vm.expectRevert(SignatureStorage.SignatureStorage__InvalidSigner.selector);
        signatureStorage.storeSignature(signature, messageHash, address(0));
    }

    function testStoreSignatureRevertsIfSignatureWontCorrespondToSigner() public {
        bytes memory signature = _signMessage(messageHash);

        address wrongSigner = makeAddr("wrongSigner");

        vm.prank(signatureStorageRole);
        vm.expectRevert(SignatureStorage.SignatureStorage__InvalidSigner.selector);
        signatureStorage.storeSignature(signature, messageHash, wrongSigner);
    }

    function testStoreSignature() public {
        bytes memory signature = _signMessage(messageHash);

        vm.prank(signatureStorageRole);
        vm.expectEmit(true, true, true, false, address(signatureStorage));
        emit OnSignatureStored(signature, signer, messageHash);
        signatureStorage.storeSignature(signature, messageHash, signer);

        assertEq(signatureStorage.signatureToSigner(signature), signer);
        assertEq(signatureStorage.signatureToMessageHash(signature), messageHash);
    }
}
