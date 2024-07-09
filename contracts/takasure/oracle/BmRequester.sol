//SPDX-License-Identifier: GPL-3.0

/**
 * @title OraceConsumer
 * @author Maikel Ordaz
 */

// todo: natspec

import {FunctionsClientMod} from "./FunctionsClientMod.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

pragma solidity 0.8.25;

contract BmRequester is FunctionsClientMod {
    using FunctionsRequest for FunctionsRequest.Request;

    bytes32 public donId;
    string public source;

    bytes32 public lastRequestId;
    bytes public lastResponse;
    bytes public lastError;

    event Response(bytes32 indexed requestId, bytes response, bytes err); // todo: this will be emited during the callback, check if chainlink need this exact name or can use OnResponse

    error OracleConsumer__UnexpectedRequestID(bytes32 requestId);

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the router.
     */
    function __BmRequester_init(
        address router,
        bytes32 _donId,
        string calldata _source
    ) internal onlyInitializing {
        __FunctionsClientMod_init(router);
        donId = _donId;
        source = _source;
    }

    /**
     */
    function fetchBM(
        // FunctionsRequest.Location secretsLocation,
        // bytes calldata encryptedSecretReference,
        string[] calldata args,
        // bytes[] calldata bytesArgs,
        uint64 subscriptionId,
        uint32 callbackGasLimit
    ) public returns (bytes32, bytes memory) {
        FunctionsRequest.Request memory req;
        req.initializeRequest(
            FunctionsRequest.Location.Inline,
            FunctionsRequest.CodeLanguage.JavaScript,
            source
        );
        // req.secretsLocation = secretsLocation;
        // req.encryptedSecretsReference = encryptedSecretReference;
        if (args.length > 0) {
            req.setArgs(args);
        }
        // if (bytesArgs.length > 0) {
        //     req.setBytesArgs(bytesArgs);
        // }

        bytes32 reqId = _sendRequest(req.encodeCBOR(), subscriptionId, callbackGasLimit, donId);
        lastRequestId = reqId;

        return (reqId, lastResponse);
    }

    /**
     * @notice Callback that is invoked when the DON response is received
     */
    function _fulfillRequest(
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