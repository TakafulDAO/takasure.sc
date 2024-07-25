//SPDX-License-Identifier: GPL-3.0

/**
 * @title FunctionsConsumer
 * @author Maikel Ordaz
 */

// todo: natspec
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";

import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

pragma solidity 0.8.25;

contract BmFetcher is Ownable, FunctionsClient {
    using FunctionsRequest for FunctionsRequest.Request;

    bytes32 private donId;
    uint32 private gasLimit;
    uint64 private subscriptionId;
    string public bmSourceRequestCode;

    bytes32 public lastRequestId;
    bytes public lastResponse;
    bytes public lastError;

    event Response(bytes32 indexed requestId, bytes response, bytes err); // todo: this will be emited during the callback, check if chainlink need this exact name or can use OnResponse

    error OracleConsumer__UnexpectedRequestID(bytes32 requestId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address router,
        bytes32 _donId,
        uint32 _gasLimit,
        uint64 _subscriptionId
    ) Ownable(msg.sender) FunctionsClient(router) {
        donId = _donId;
        gasLimit = _gasLimit;
        subscriptionId = _subscriptionId;
    }

    /**
     * @notice Send a simple request
     * @param args List of arguments accessible from within the source code
     */
    function sendRequest(string[] memory args) external onlyOwner returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(bmSourceRequestCode);

        if (args.length > 0) req.setArgs(args);
        lastRequestId = _sendRequest(req.encodeCBOR(), subscriptionId, gasLimit, donId);
        return lastRequestId;
    }

    /// @notice the next set of functions are used to set the values of the contract
    function setDonId(bytes32 _donId) external onlyOwner {
        donId = _donId;
    }

    function setGasLimit(uint32 _gasLimit) external onlyOwner {
        gasLimit = _gasLimit;
    }

    function setSubscriptionId(uint64 _subscriptionId) external onlyOwner {
        subscriptionId = _subscriptionId;
    }

    function setBMSourceRequestCode(string calldata _bmSourceRequestCode) external onlyOwner {
        bmSourceRequestCode = _bmSourceRequestCode;
    }

    /**
     * @notice Callback that is invoked when the DON response is received
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        if (requestId != lastRequestId) {
            revert OracleConsumer__UnexpectedRequestID(requestId);
        }
        lastResponse = response;
        lastError = err;

        emit Response(requestId, response, err);
    }
}
