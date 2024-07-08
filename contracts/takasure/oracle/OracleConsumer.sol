//SPDX-License-Identifier: GPL-3.0

/**
 * @title OraceConsumer
 * @author Maikel Ordaz
 */

import {FunctionsClientMod} from "./FunctionsClientMod.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

pragma solidity 0.8.25;

contract OracleConsumer is FunctionsClientMod {
    using FunctionsRequest for FunctionsRequest.Request;

    bytes32 public donId;

    bytes32 public lastRequestId;
    bytes public lastResponse;
    bytes public lastError;

    event Response(bytes32 indexed requestId, bytes response, bytes err); // todo: this will be emited during the callback, check if chainlink need this exact name or can use OnResponse

    error OracleConsumer__UnexpectedRequestID(bytes32 requestId);

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the router.
     */
    function __OracleConsumer_init(address router, bytes32 _donId) internal onlyInitializing {
        __OracleConsumer_init_unchained(router);
        donId = _donId;
    }

    function __OracleConsumer_init_unchained(address _router) internal onlyInitializing {
        __FunctionsClient_init(_router);
    }

    /**
     * todo: here I make the call with _sendResquest
     * Maybe source in initializer?
     */
    function fetchBM(
        string calldata source,
        FunctionsRequest.Location secretsLocation,
        bytes calldata encryptedSecretReference,
        string[] calldata args,
        bytes[] calldata bytesArgs,
        uint64 subscriptionId,
        uint32 callbackGasLimit
    ) public returns (bytes32) {
        FunctionsRequest.Request memory req;
        req.initializeRequest(
            FunctionsRequest.Location.Inline,
            FunctionsRequest.CodeLanguage.JavaScript,
            source
        );
        req.secretsLocation = secretsLocation;
        req.encryptedSecretsReference = encryptedSecretReference;
        if (args.length > 0) {
            req.setArgs(args);
        }
        if (bytesArgs.length > 0) {
            req.setBytesArgs(bytesArgs);
        }

        lastRequestId = _sendRequest(req.encodeCBOR(), subscriptionId, callbackGasLimit, donId);

        return lastRequestId;
    }

    /**
     * @notice Callback that is ivoked when the DON response is received
     */
    function _fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {}
}
