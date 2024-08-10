//SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

interface IBenefitMultiplierConsumer {
    function idToBenefitMultiplier(
        bytes32 requestId
    ) external view returns (uint256 benefitMultiplier);

    function idToErrorResponse(
        bytes32 requestId
    ) external view returns (bytes memory errorResponse);

    function idToSuccessResponse(
        bytes32 requestId
    ) external view returns (bytes memory successResponse);

    function idToSuccessRequest(bytes32 requestId) external view returns (bool successRequest);

    function memberToRequestId(string memory member) external view returns (bytes32 requestId);

    function sendRequest(string[] memory args) external returns (bytes32 requestId);
}
