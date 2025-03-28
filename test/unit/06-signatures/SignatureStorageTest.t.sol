// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {SignatureStorage} from "contracts/helpers/SignatureStorage.sol";

contract SignatureStorageTest is Test {
    SignatureStorage signatureStorage;

    function setUp() public {
        signatureStorage = new SignatureStorage();
    }
}
