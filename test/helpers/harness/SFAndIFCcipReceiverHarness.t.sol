// SPDX-License-Identifier: GNU GPLv3
/// @dev This contract is used to be able to test some internal functions

pragma solidity 0.8.28;

import {SFAndIFCcipReceiver} from "contracts/helpers/chainlink/SFAndIFCcipReceiver.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";

contract SFAndIFCcipReceiverHarness is SFAndIFCcipReceiver {
    constructor() SFAndIFCcipReceiver(IAddressManager(address(1)), address(2), address(3)) {}

    function exposed__decodeMessageData(
        bytes memory data
    ) external pure returns (string memory protocolName_, bytes memory protocolCallData_) {
        return _decodeMessageData(data);
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
