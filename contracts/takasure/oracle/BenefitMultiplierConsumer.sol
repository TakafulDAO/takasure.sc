//SPDX-License-Identifier: GPL-3.0

/**
 * @title BenefitMultiplierConsumer
 * @author Maikel Ordaz
 * @notice This contract is used to fetch the benefit multiplier to be used in the Life Dao protocol
 */

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";

import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

pragma solidity 0.8.25;

contract BenefitMultiplierConsumer is AccessControl, FunctionsClient {
    using FunctionsRequest for FunctionsRequest.Request;

    bytes32 public constant BM_REQUESTER_ROLE = keccak256("BM_REQUESTER_ROLE");

    address public requester;

    bytes32 private donId;
    uint32 private gasLimit;
    uint64 private subscriptionId;
    string public bmSourceRequestCode;

    bytes32 public lastRequestId;
    bytes public lastResponse;
    bytes public lastError;

    mapping(bytes32 requestId => bool successRequest) public idToSuccessRequest;
    mapping(bytes32 requestId => bytes successResponse) public idToSuccessResponse;
    mapping(bytes32 requestId => bytes errorResponse) public idToErrorResponse;
    mapping(bytes32 requestId => uint256 benefitMultiplier) public idToBenefitMultiplier;
    mapping(string member => bytes32 requestId) public memberToRequestId;

    event OnBenefitMultiplierResponse(bytes32 indexed requestId, bytes response, bytes err);

    error OracleConsumer__UnexpectedRequestID(bytes32 requestId);
    error OracleConsumer__NotAddressZero();

    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     * @param router The address of the Chainlink node
     * @param _donId The data provider ID
     * @param _gasLimit The gas limit for the request
     * @param _subscriptionId The subscription ID
     */
    constructor(
        address router,
        bytes32 _donId,
        uint32 _gasLimit,
        uint64 _subscriptionId
    ) FunctionsClient(router) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        donId = _donId;
        gasLimit = _gasLimit;
        subscriptionId = _subscriptionId;
    }

    function setNewRequester(address newRequester) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRequester == address(0)) revert OracleConsumer__NotAddressZero();
        if (requester != address(0)) _revokeRole(BM_REQUESTER_ROLE, requester);
        _grantRole(BM_REQUESTER_ROLE, newRequester);
        requester = newRequester;
    }

    /**
     * @notice Send a simple request
     * @param args The user address to get the BM
     */
    function sendRequest(
        string[] memory args
    ) external onlyRole(BM_REQUESTER_ROLE) returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(bmSourceRequestCode);

        if (args.length > 0) req.setArgs(args);
        lastRequestId = _sendRequest(req.encodeCBOR(), subscriptionId, gasLimit, donId);
        memberToRequestId[args[0]] = lastRequestId;
        requestId = lastRequestId;
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
        lastResponse = response;
        lastError = err;

        if (err.length > 0) {
            idToSuccessRequest[requestId] = false;
            idToErrorResponse[requestId] = err;
        } else {
            idToSuccessRequest[requestId] = true;
            idToSuccessResponse[requestId] = response;
            idToBenefitMultiplier[requestId] = abi.decode(response, (uint256));
        }

        emit OnBenefitMultiplierResponse(requestId, response, err);
    }
}
