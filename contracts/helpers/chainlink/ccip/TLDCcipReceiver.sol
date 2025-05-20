//SPDX-License-Identifier: GNU GPLv3

/**
 * @title TLDCcipReceiver
 * @author Maikel Ordaz
 * @notice This contract will:
 *          - Interact with the CCIP pprotocol
 *          - Receive data from the Sender contract
 *          - Perform a call to the PrejoinModule with the data received
 *          - Deployed only in Arbitrum (One and Sepolia)
 */
pragma solidity 0.8.28;

import {Client} from "ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract TLDCcipReceiver is CCIPReceiver, Ownable2Step {
    using SafeERC20 for IERC20;
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;

    IERC20 public immutable usdc;
    address public protocolGateway; // The address of the contract to perform the low level call with the data received.

    mapping(uint64 chainSelector => mapping(address sender => bool)) public isSenderAllowedByChain;
    mapping(bytes32 messageId => Client.Any2EVMMessage message) public messageContentsById;
    mapping(address user => Client.Any2EVMMessage message) public messageByUser;
    mapping(address user => bytes32 messageId) public messageIdByUser;
    EnumerableMap.Bytes32ToUintMap internal failedMessages;

    enum StatusCode {
        FAILED, // Messages that receives this contract, but is not able to make the low level call
        RESOLVED, // Failed messages that are successfull after retry
        RECOVERED // Failed messages the user recover the tokens
    }

    struct FailedMessage {
        bytes32 messageId;
        StatusCode statusCode;
    }

    event OnProtocolGatewayChanged(
        address indexed oldProtocolGateway,
        address indexed newProtocolGateway
    );
    event OnMessageReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed sender,
        bytes data,
        uint256 tokenAmount
    );
    event OnMessageFailed(bytes32 indexed messageId, bytes reason, address user);
    event OnMessageRecovered(bytes32 indexed messageId);
    event OnTokensRecovered(address indexed user, uint256 amount);

    error TLDCcipReceiver__NotZeroAddress();
    error TLDCcipReceiver__InvalidUsdcToken();
    error TLDCcipReceiver__NotAllowedSource();
    error TLDCcipReceiver__OnlySelf();
    error TLDCcipReceiver__CallFailed();
    error TLDCcipReceiver__MessageNotFailed(bytes32 messageId);
    error TLDCcipReceiver__NotAuthorized();

    /**
     * @param _sourceChainSelector Identify the source blockchain
     * @param _sender Identify the sender contract in the source blockchain
     */
    modifier onlyAllowedSource(uint64 _sourceChainSelector, address _sender) {
        require(
            isSenderAllowedByChain[_sourceChainSelector][_sender],
            TLDCcipReceiver__NotAllowedSource()
        );
        _;
    }

    modifier onlyOwnerOrUser(address user) {
        require(msg.sender == owner() || msg.sender == user, TLDCcipReceiver__NotAuthorized());
        _;
    }

    /**
     * @param _router The address of the router contract.
     * @param _usdc The address of the usdc contract.
     * @param _protocolGateway The address of the contract to perform the low level call with the data received.
     */
    constructor(
        address _router,
        address _usdc,
        address _protocolGateway
    ) CCIPReceiver(_router) Ownable(msg.sender) {
        require(_usdc != address(0), TLDCcipReceiver__InvalidUsdcToken());
        usdc = IERC20(_usdc);
        protocolGateway = _protocolGateway;
    }

    /*//////////////////////////////////////////////////////////////
                                SETTINGS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allows the owner to enable/disable a sender.
     * @param chainSelector source chain
     * @param sender The address of the sender contract.
     */
    function toggleAllowedSender(uint64 chainSelector, address sender) external onlyOwner {
        require(sender != address(0), TLDCcipReceiver__NotAllowedSource());
        bool enable = !isSenderAllowedByChain[chainSelector][sender];
        isSenderAllowedByChain[chainSelector][sender] = enable;
    }

    /**
     * @notice Allows the owner to change the address of the protocol gateway.
     * @param _protocolGateway The address of the contract to perform the low level call with the data received.
     */
    function setProtocolGateway(address _protocolGateway) external onlyOwner {
        require(_protocolGateway != address(0), TLDCcipReceiver__NotZeroAddress());

        address oldProtocolGateway = protocolGateway;
        protocolGateway = _protocolGateway;

        emit OnProtocolGatewayChanged(oldProtocolGateway, _protocolGateway);
    }

    /*//////////////////////////////////////////////////////////////
                            RECEIVE MESSAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice CCIP router calls this function. Should never revert, errors are handled internally
     * @param any2EvmMessage The message to process
     * @dev Only router can call
     */
    function ccipReceive(
        Client.Any2EVMMessage calldata any2EvmMessage
    )
        external
        override
        onlyRouter
        onlyAllowedSource(
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address))
        )
    {
        // Try-catch to avoid reverting the tx, emit event instead
        // Try catch to be able to call the external function
        try this.processMessage(any2EvmMessage) {} catch (bytes memory) {
            failedMessages.set(any2EvmMessage.messageId, uint256(StatusCode.FAILED));

            messageContentsById[any2EvmMessage.messageId] = any2EvmMessage;

            // Save the message by user for easy access
            address user = _getNewMemberAddress(any2EvmMessage.data);
            messageByUser[user] = any2EvmMessage;
            messageIdByUser[user] = any2EvmMessage.messageId;

            return;
        }
    }

    /**
     * @notice It process the message received from the CCIP protocol.
     * @param any2EvmMessage Received CCIP message.
     */
    function processMessage(
        Client.Any2EVMMessage calldata any2EvmMessage
    )
        external
        onlyAllowedSource(
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address))
        )
    {
        if (msg.sender != address(this)) revert TLDCcipReceiver__OnlySelf();
        _ccipReceive(any2EvmMessage);
    }

    /**
     * @notice Allows the owner to retry a failed message in order to unblock the associated tokens.
     * @param user The user which message failed
     * @dev This function is only callable by the user or contract owner
     * @dev It changes the status of the message from 'failed' to 'resolved'
     */
    function retryFailedMessage(address user) external onlyOwnerOrUser(user) {
        (Client.Any2EVMMessage memory message, bytes32 messageId) = _getUserMessage(user);

        failedMessages.set(messageId, uint256(StatusCode.RESOLVED));

        // Approve the protocol gateway to spend the USDC tokens
        usdc.approve(protocolGateway, message.destTokenAmounts[0].amount);

        // Low level call to the referral gateway
        (bool success, ) = protocolGateway.call(message.data);
        require(success, TLDCcipReceiver__CallFailed());

        emit OnMessageRecovered(messageId);
    }

    /**
     * @notice An emergency function to allow a user to recover their tokens in case of a failed message.
     * @param user The user which message failed
     * @dev This function is only callable by the user or the contract owner
     */
    function recoverTokens(address user) external onlyOwnerOrUser(user) {
        (Client.Any2EVMMessage memory message, bytes32 messageId) = _getUserMessage(user);

        failedMessages.set(messageId, uint256(StatusCode.RECOVERED));

        // Transfer the tokens back to the user
        usdc.safeTransfer(user, message.destTokenAmounts[0].amount);

        emit OnTokensRecovered(user, message.destTokenAmounts[0].amount);
    }

    /**
     * @notice Retrieves a paginated list of failed messages.
     * @param offset The index of the first failed message to return, enabling pagination by skipping a specified number of messages
     * @param limit The maximum number of failed messages to return, this is the size of the returned array
     * @return failedMessages. Array of `FailedMessage` struct, with a `messageId` and an `statusCode` (RESOLVED or FAILED)
     */
    function getFailedMessages(
        uint256 offset,
        uint256 limit
    ) external view returns (FailedMessage[] memory) {
        uint256 length = failedMessages.length();

        uint256 returnLength = (offset + limit > length) ? length - offset : limit;
        FailedMessage[] memory failedMessagesList = new FailedMessage[](returnLength);

        for (uint256 i; i < returnLength; ++i) {
            (bytes32 messageId, uint256 statusCode) = failedMessages.at(offset + i);
            failedMessagesList[i] = FailedMessage(messageId, StatusCode(statusCode));
        }
        return failedMessagesList;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        // Approve the protocol gateway to spend the USDC tokens
        usdc.approve(protocolGateway, any2EvmMessage.destTokenAmounts[0].amount);

        // Low level call to the referral gateway
        (bool success, bytes memory returnData) = protocolGateway.call(any2EvmMessage.data);
        if (success) {
            emit OnMessageReceived(
                any2EvmMessage.messageId,
                any2EvmMessage.sourceChainSelector,
                abi.decode(any2EvmMessage.sender, (address)),
                any2EvmMessage.data,
                any2EvmMessage.destTokenAmounts[0].amount
            );
        } else {
            address _userAddress = _getNewMemberAddress(any2EvmMessage.data);
            emit OnMessageFailed(any2EvmMessage.messageId, returnData, _userAddress);
        }
    }

    function _getNewMemberAddress(bytes memory _data) internal pure returns (address _newMember) {
        // The data is structured to be able to call the function payContributionOnBehalfOf
        // payContributionOnBehalfOf(uint256 contribution, string calldata tDAOName, address parent, address newMember, uint256 couponAmount)

        assembly {
            let _dataOffset := add(_data, 0x20) // Skip the first 32 bytes word from the data, this will point to the real place where the data starts
            let _newMemberStartingPoint := mul(0x03, 0x20) // 0x03 is the input index (0-indexed of the newMember), 0x20 is the length of a 32 bytes word
            let _inputsStartingPoint := add(0x04, _newMemberStartingPoint) // 0x04 is the length of the function selector

            _newMember := mload(add(_dataOffset, _inputsStartingPoint)) // Load the newMember address from the data
        }

        return _newMember;
    }

    function _getUserMessage(
        address _user
    ) internal view returns (Client.Any2EVMMessage memory _message, bytes32 _messageId) {
        _messageId = messageIdByUser[_user];

        require(
            failedMessages.get(_messageId) == uint256(StatusCode.FAILED),
            TLDCcipReceiver__MessageNotFailed(_messageId)
        );

        _message = messageContentsById[_messageId];
    }
}
