//SPDX-License-Identifier: GPL-3.0

/**
 * @title OraceConsumer
 * @author Maikel Ordaz
 */

import {FunctionsClientMod} from "./FunctionsClientMod.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

pragma solidity 0.8.25;

abstract contract OracleConsumer is FunctionsClientMod {
    using FunctionsRequest for FunctionsRequest.Request;

    bytes32 public lastRequestId;
    bytes public lastResponse;
    bytes public lastError;

    event Response(bytes32 indexed requestId, bytes response, bytes err); // todo: this will be emited during the callback, check if chainlink need this exact name or can use OnResponse

    error OracleConsumer__UnexpectedRequestID(bytes32 requestId);

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the router.
     */
    function __OracleConsumer_init(address router) internal onlyInitializing {
        __OracleConsumer_init_unchained(router);
    }

    function __OracleConsumer_init_unchained(address _router) internal onlyInitializing {
        __FunctionsClient_init(_router);
    }
}
