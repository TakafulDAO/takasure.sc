//SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

interface IBmFetcher {
    /**
     * @notice Send a simple request
     * @param args The user address to get the BM
     */
    function sendRequest(string[] memory args) external returns (bytes32 requestId);

    /**
     * @notice a method convert the last response to an uint256
     */
    function convertResponseToUint() external view returns (uint256);
}
