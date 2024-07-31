//SPDX-License-Identifier: GPL-3.0

/**
 * @title BenefitMultiplierConsumerMockBad
 * @author Maikel Ordaz
 * @notice This contract mocks an error response from the benefit multiplier oracle
 */

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";

import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

pragma solidity 0.8.25;

contract BenefitMultiplierConsumerMockError is AccessControl, FunctionsClient {
    using FunctionsRequest for FunctionsRequest.Request;

    bytes32 public constant BM_REQUESTER_ROLE = keccak256("BM_REQUESTER_ROLE");

    bytes32 private donId;
    uint32 private gasLimit;
    uint64 private subscriptionId;
    string public bmSourceRequestCode;

    bytes32 public lastRequestId;
    bytes public lastResponse;
    bytes public lastError;

    event Response(bytes32 indexed requestId, bytes response, bytes err); // todo: this will be emited during the callback, check if chainlink need this exact name or can use OnResponse

    error OracleConsumer__UnexpectedRequestID(bytes32 requestId);

    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     * @param router The address of the Chainlink node
     * @param _donId The data provider ID
     * @param _gasLimit The gas limit for the request
     * @param _subscriptionId The subscription ID
     * @param requester The address allowed to request the benefit multiplier. Will be the takasure contract
     */
    constructor(
        address router,
        bytes32 _donId,
        uint32 _gasLimit,
        uint64 _subscriptionId,
        address requester
    ) FunctionsClient(router) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BM_REQUESTER_ROLE, requester);
        donId = _donId;
        gasLimit = _gasLimit;
        subscriptionId = _subscriptionId;
    }

    /**
     * @notice Send a simple request
     * @param args The user address to get the BM
     */
    function sendRequest(
        string[] memory args
    ) external onlyRole(BM_REQUESTER_ROLE) returns (bytes32 requestId) {
        bytes32 newRequestId = bytes32(uint256(lastRequestId) + 1);
        // Then we set the response and error
        bytes memory response = "";
        bytes memory err = abi.encode("Failed response");

        // Call the callback
        fulfillRequest(newRequestId, response, err);

        // And return the newRequestId
        lastRequestId = newRequestId;
        requestId = newRequestId;
    }

    /**
     * @notice a method convert the last response to an uint256
     */
    function convertResponseToUint() external view returns (uint256) {
        return abi.decode(lastResponse, (uint256));
    }

    /// @notice the next set of functions are used to set the values of the contract
    function setDonId(bytes32 _donId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        donId = _donId;
    }

    function setGasLimit(uint32 _gasLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        gasLimit = _gasLimit;
    }

    function setSubscriptionId(uint64 _subscriptionId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        subscriptionId = _subscriptionId;
    }

    function setBMSourceRequestCode(
        string calldata _bmSourceRequestCode
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
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
