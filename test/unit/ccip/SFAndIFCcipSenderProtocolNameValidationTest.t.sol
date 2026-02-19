// SPDX-License-Identifier: GNU GPLv3
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SFAndIFCcipSenderHarness} from "test/helpers/harness/SFAndIFCcipSenderHarness.t.sol";

contract SFAndIFCcipSenderProtocolNameValidationTest is Test {
    SFAndIFCcipSenderHarness private harness;

    function setUp() public {
        harness = new SFAndIFCcipSenderHarness();
    }

    function testSFAndIFCcip_sender_protocolNameValidation_acceptsValidName() public view {
        bool valid = harness.exposed__isValidProtocolName("PROTOCOL__SF_VAULT");
        assertTrue(valid, "valid protocol name should pass");
    }

    function testSFAndIFCcip_sender_protocolNameValidation_acceptsValidNameWithDigitsAndUnderscores() public view {
        bool valid = harness.exposed__isValidProtocolName("PROTOCOL__IF_2026_ALPHA_VAULT");
        assertTrue(valid, "upper case, digits and underscores should pass");
    }

    function testSFAndIFCcip_sender_protocolNameValidation_acceptsMaxLengthName() public view {
        // 10 (`PROTOCOL__`) + 16 (`ABCDEFGHIJKLMNOP`) + 6 (`_VAULT`) = 32 chars.
        bool valid = harness.exposed__isValidProtocolName("PROTOCOL__ABCDEFGHIJKLMNOP_VAULT");
        assertTrue(valid, "32-char protocol name should pass");
    }

    function testSFAndIFCcip_sender_protocolNameValidation_rejectsLengthAbove32() public view {
        // 10 (`PROTOCOL__`) + 17 (`ABCDEFGHIJKLMNOPQ`) + 6 (`_VAULT`) = 33 chars.
        bool valid = harness.exposed__isValidProtocolName("PROTOCOL__ABCDEFGHIJKLMNOPQ_VAULT");
        assertFalse(valid, "name longer than 32 chars should fail");
    }

    function testSFAndIFCcip_sender_protocolNameValidation_rejectsEmptyScope() public view {
        bool valid = harness.exposed__isValidProtocolName("PROTOCOL___VAULT");
        assertFalse(valid, "scope between prefix and suffix must be non-empty");
    }

    function testSFAndIFCcip_sender_protocolNameValidation_rejectsInvalidPrefix() public view {
        bool valid = harness.exposed__isValidProtocolName("PROT0COL__SF_VAULT");
        assertFalse(valid, "invalid prefix should fail");
    }

    function testSFAndIFCcip_sender_protocolNameValidation_rejectsInvalidSuffix() public view {
        bool valid = harness.exposed__isValidProtocolName("PROTOCOL__SF_VAULX");
        assertFalse(valid, "invalid suffix should fail");
    }

    function testSFAndIFCcip_sender_protocolNameValidation_rejectsLowercaseScopeCharacters() public view {
        bool valid = harness.exposed__isValidProtocolName("PROTOCOL__sf_VAULT");
        assertFalse(valid, "lowercase scope chars should fail");
    }

    function testSFAndIFCcip_sender_protocolNameValidation_rejectsInvalidScopeCharacters() public view {
        bool valid = harness.exposed__isValidProtocolName("PROTOCOL__SF-VAULT_VAULT");
        assertFalse(valid, "invalid scope charset should fail");
    }
}
