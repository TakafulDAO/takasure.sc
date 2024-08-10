// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {BenefitMultiplierConsumerMockSuccess} from "test/mocks/BenefitMultiplierConsumerMockSuccess.sol";

contract SimulateDonResponse {
    function _successResponse(address consumer) internal {
        bytes32 requestId = bytes32(uint256(1));
        bytes memory response = abi.encode(100046); // Bm 100046
        bytes memory err = "";
        BenefitMultiplierConsumerMockSuccess(consumer).simulateDonResponse(
            requestId,
            response,
            err
        );
    }

    function _errorResponse(address consumer) internal {
        bytes32 requestId = bytes32(uint256(1));
        bytes memory response = "";
        bytes memory err = abi.encode("This went wrong");
        BenefitMultiplierConsumerMockSuccess(consumer).simulateDonResponse(
            requestId,
            response,
            err
        );
    }
}
