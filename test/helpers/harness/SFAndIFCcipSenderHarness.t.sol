// SPDX-License-Identifier: GNU GPLv3
/// @dev This contract is used to be able to test some internal functions

pragma solidity 0.8.28;

import {SFAndIFCcipSender} from "contracts/helpers/chainlink/SFAndIFCcipSender.sol";

contract SFAndIFCcipSenderHarness is SFAndIFCcipSender {
    function exposed__isValidProtocolName(string memory protocolName) external pure returns (bool isValid_) {
        isValid_ = _isValidProtocolName(protocolName);
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
