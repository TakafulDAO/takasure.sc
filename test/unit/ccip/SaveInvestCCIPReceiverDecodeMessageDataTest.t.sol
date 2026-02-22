// SPDX-License-Identifier: GNU GPLv3
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SaveInvestCCIPReceiver} from "contracts/helpers/chainlink/SaveInvestCCIPReceiver.sol";
import {SaveInvestCCIPReceiverHarness} from "test/helpers/harness/SaveInvestCCIPReceiverHarness.t.sol";

contract SaveInvestCCIPReceiverDecodeMessageDataTest is Test {
    SaveInvestCCIPReceiverHarness private harness;

    function setUp() public {
        harness = new SaveInvestCCIPReceiverHarness();
    }

    function testSaveInvestCCIP_receiver_decodeMessageData_decodesValidPayload() public view {
        string memory protocolName = "PROTOCOL__SF_VAULT";
        address user = address(0xBEEF);
        bytes memory protocolCallData = abi.encodeWithSignature("deposit(uint256,address)", 25e6, user);

        (string memory decodedName, bytes memory decodedCallData) =
            harness.exposed__decodeMessageData(abi.encode(protocolName, protocolCallData));

        assertEq(decodedName, protocolName, "decoded protocol name mismatch");
        assertEq(keccak256(decodedCallData), keccak256(protocolCallData), "decoded protocol call data mismatch");
    }

    function testSaveInvestCCIP_receiver_decodeMessageData_decodesEmptyProtocolCallData() public view {
        string memory protocolName = "PROTOCOL__IF_VAULT";
        bytes memory protocolCallData = "";

        (string memory decodedName, bytes memory decodedCallData) =
            harness.exposed__decodeMessageData(abi.encode(protocolName, protocolCallData));

        assertEq(decodedName, protocolName, "decoded protocol name mismatch");
        assertEq(decodedCallData.length, 0, "decoded protocol call data should be empty");
    }

    function testSaveInvestCCIP_receiver_decodeMessageData_revertsForShortPayload() public {
        vm.expectRevert(SaveInvestCCIPReceiver.SaveInvestCCIPReceiver__InvalidMessageData.selector);
        harness.exposed__decodeMessageData(hex"1234");
    }

    function testSaveInvestCCIP_receiver_decodeMessageData_revertsWhenProtocolNameOffsetIsOutOfBounds() public {
        bytes memory malformed = abi.encode(uint256(0xFFFF), bytes("abc"));

        vm.expectRevert(SaveInvestCCIPReceiver.SaveInvestCCIPReceiver__InvalidMessageData.selector);
        harness.exposed__decodeMessageData(malformed);
    }

    function testSaveInvestCCIP_receiver_decodeMessageData_revertsWhenProtocolCallDataOffsetIsOutOfBounds() public {
        bytes memory malformed = abi.encode("PROTOCOL__SF_VAULT", uint256(0xFFFF));

        vm.expectRevert(SaveInvestCCIPReceiver.SaveInvestCCIPReceiver__InvalidMessageData.selector);
        harness.exposed__decodeMessageData(malformed);
    }

    function testSaveInvestCCIP_receiver_decodeMessageData_revertsWhenProtocolNameLengthOverflowsPayload() public {
        bytes memory malformed = abi.encode("PROTOCOL__SF_VAULT", bytes("abcd"));
        _setProtocolNameLength(malformed, type(uint256).max);

        vm.expectRevert(SaveInvestCCIPReceiver.SaveInvestCCIPReceiver__InvalidMessageData.selector);
        harness.exposed__decodeMessageData(malformed);
    }

    function testSaveInvestCCIP_receiver_decodeMessageData_revertsWhenProtocolCallDataLengthOverflowsPayload() public {
        bytes memory malformed = abi.encode("PROTOCOL__SF_VAULT", bytes("abcd"));
        _setProtocolCallDataLength(malformed, type(uint256).max);

        vm.expectRevert(SaveInvestCCIPReceiver.SaveInvestCCIPReceiver__InvalidMessageData.selector);
        harness.exposed__decodeMessageData(malformed);
    }

    function _setProtocolNameLength(bytes memory data, uint256 newLength) internal pure {
        uint256 protocolNameOffset;
        assembly {
            protocolNameOffset := mload(add(data, 0x20))
        }

        assembly {
            let payloadStart := add(data, 0x20)
            let protocolNameLengthPos := add(payloadStart, protocolNameOffset)
            mstore(protocolNameLengthPos, newLength)
        }
    }

    function _setProtocolCallDataLength(bytes memory data, uint256 newLength) internal pure {
        uint256 protocolCallDataOffset;
        assembly {
            protocolCallDataOffset := mload(add(data, 0x40))
        }

        assembly {
            let payloadStart := add(data, 0x20)
            let protocolCallDataLengthPos := add(payloadStart, protocolCallDataOffset)
            mstore(protocolCallDataLengthPos, newLength)
        }
    }
}
