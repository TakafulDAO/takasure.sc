//SPDX-License-Identifier: GPL-3.0

/**
 * @title FunctionsConsumer
 * @author Maikel Ordaz
 */

// todo: natspec
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {FunctionsClientMod, Initializable} from "./FunctionsClientMod.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

pragma solidity 0.8.25;

contract FunctionsConsumer is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    FunctionsClientMod
{
    using FunctionsRequest for FunctionsRequest.Request;

    bytes32 private donId;
    uint64 private subscriptionId;
    string public bmSourceRequestCode;

    bytes32 public lastRequestId;
    bytes public lastResponse;
    bytes public lastError;

    event Response(bytes32 indexed requestId, bytes response, bytes err); // todo: this will be emited during the callback, check if chainlink need this exact name or can use OnResponse

    error OracleConsumer__UnexpectedRequestID(bytes32 requestId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address router,
        bytes32 _donId,
        uint64 _subscriptionId,
        string calldata _bmSourceRequestCode
    ) external {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
        __FunctionsClientMod_init(router);
        donId = _donId;
        subscriptionId = _subscriptionId;
        bmSourceRequestCode = _bmSourceRequestCode;
    }

    function setDonId(bytes32 _donId) external onlyOwner {
        donId = _donId;
    }

    function setSubscriptionId(uint64 _subscriptionId) external onlyOwner {
        subscriptionId = _subscriptionId;
    }

    function setBMSourceRequestCode(string calldata _bmSourceRequestCode) external onlyOwner {
        bmSourceRequestCode = _bmSourceRequestCode;
    }

    /**
     * @notice Send a simple request
     * @param args List of arguments accessible from within the source code
     * @param bytesArgs Array of bytes arguments, represented as hex strings
     */
    function sendRequest(
        string[] memory args,
        bytes[] memory bytesArgs,
        uint32 gasLimit
    ) external onlyOwner returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(bmSourceRequestCode);

        if (args.length > 0) req.setArgs(args);
        if (bytesArgs.length > 0) req.setBytesArgs(bytesArgs);
        lastRequestId = _sendRequest(req.encodeCBOR(), subscriptionId, gasLimit, donId);
        return lastRequestId;
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

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
