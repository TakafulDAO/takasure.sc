// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title IReceiver
 * @notice Minimal Chainlink CRE receiver interface expected by the KeystoneForwarder.
 * @dev Implementations must also support ERC165 interface detection.
 */
interface IReceiver is IERC165 {
    /**
     * @notice Handles an incoming CRE report.
     * @param metadata Workflow metadata packed by the forwarder as
     *        `abi.encodePacked(bytes32 workflowId, bytes10 workflowName, address workflowOwner)`.
     * @param report ABI-encoded workflow payload.
     */
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
