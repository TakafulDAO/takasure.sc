// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IFunctionsRouter} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/interfaces/IFunctionsRouter.sol";
import {IFunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/interfaces/IFunctionsClient.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

/// @title The Chainlink Functions client contract
/// @notice Contract developers can inherit this contract in order to make Chainlink Functions requests
/// @notice This is a modified FunctionsClient contract from Chainlink to be able  to inherit in upgradeable contracts
abstract contract FunctionsClientMod is Initializable, IFunctionsClient {
    using FunctionsRequest for FunctionsRequest.Request;

    IFunctionsRouter internal functionsRouter; // No longer immutable as we dont have a constructor now. No way to set a new value

    event RequestSent(bytes32 indexed id);
    event RequestFulfilled(bytes32 indexed id);

    error OnlyRouterCanFulfill();

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the router.
     */
    function __FunctionsClientMod_init(address router) internal onlyInitializing {
        __FunctionsClientMod_init_unchained(router);
    }

    function __FunctionsClientMod_init_unchained(address _router) internal onlyInitializing {
        functionsRouter = IFunctionsRouter(_router);
    }

    /// @notice Sends a Chainlink Functions request
    /// @param data The CBOR encoded bytes data for a Functions request
    /// @param subscriptionId The subscription ID that will be charged to service the request
    /// @param callbackGasLimit the amount of gas that will be available for the fulfillment callback
    /// @return requestId The generated request ID for this request
    function _sendRequest(
        bytes memory data,
        uint64 subscriptionId,
        uint32 callbackGasLimit,
        bytes32 donId
    ) internal returns (bytes32) {
        bytes32 requestId = functionsRouter.sendRequest(
            subscriptionId,
            data,
            FunctionsRequest.REQUEST_DATA_VERSION,
            callbackGasLimit,
            donId
        );
        emit RequestSent(requestId);
        return requestId;
    }

    /// @notice User defined function to handle a response from the DON
    /// @param requestId The request ID, returned by sendRequest()
    /// @param response Aggregated response from the execution of the user's source code
    /// @param err Aggregated error from the execution of the user code or from the execution pipeline
    /// @dev Either response or error parameter will be set, but never both
    function _fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal virtual;

    /// @inheritdoc IFunctionsClient
    function handleOracleFulfillment(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) external override {
        if (msg.sender != address(functionsRouter)) {
            revert OnlyRouterCanFulfill();
        }
        _fulfillRequest(requestId, response, err);
        emit RequestFulfilled(requestId);
    }
}
