//SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

interface IBenefitMultiplierConsumer {
    function idToBenefitMultiplier(
        bytes32 requestId
    ) external view returns (uint256 benefitMultiplier);

    function idToError(bytes32 requestId) external view returns (bytes memory error);

    function idToResponse(bytes32 requestId) external view returns (bytes memory response);

    function idToSuccessRequest(bytes32 requestId) external view returns (bool successRequest);

    function memberToRequestId(string memory member) external view returns (bytes32 requestId);

    function sendRequest(string[] memory args) external returns (bytes32 requestId);
}
