//SPDX-License-Identifier: GNU GPLv3

/**
 * @title TLDCcipReceiver
 * @author Maikel Ordaz
 * @notice This contract will:
 *          - Interact with the CCIP pprotocol
 *          - Receive data from the Sender contract
 *          - Perform a call to the ReferralGateway with the data received
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
    address public referralGateway;

    mapping(uint64 chainSelector => bool) public isSourceChainAllowed;
    mapping(address sender => bool) public isSenderAllowed;
    mapping(bytes32 messageId => Client.Any2EVMMessage message) public messageContentsById;
    EnumerableMap.Bytes32ToUintMap internal failedMessages;

    enum ErrorCode {
        RESOLVED,
        FAILED
    }

    struct FailedMessage {
        bytes32 messageId;
        ErrorCode errorCode;
    }

    event OnMessageReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed sender,
        bytes data,
        uint256 tokenAmount
    );
    event OnMessageFailed(bytes32 indexed messageId, bytes reason);
    event OnMessageRecovered(bytes32 indexed messageId);

    error TLDCcipReceiver__InvalidUsdcToken();
    error TLDCcipReceiver__NotAllowedSource();
    error TLDCcipReceiver__OnlySelf();
    error TLDCcipReceiver__CallFailed();
    error TLDCcipReceiver__MessageNotFailed(bytes32 messageId);

    modifier onlyAllowedSource(uint64 _sourceChainSelector, address _sender) {
        require(
            _sourceChainSelector != 0 &&
                isSourceChainAllowed[_sourceChainSelector] &&
                isSenderAllowed[_sender],
            TLDCcipReceiver__NotAllowedSource()
        );
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert TLDCcipReceiver__OnlySelf();
        _;
    }

    /**
     * @param _router The address of the router contract.
     * @param _usdc The address of the usdc contract.
     * @param _referralGateway The address of the staker contract.
     */
    constructor(
        address _router,
        address _usdc,
        address _referralGateway
    ) CCIPReceiver(_router) Ownable(msg.sender) {
        require(_usdc != address(0), TLDCcipReceiver__InvalidUsdcToken());
        usdc = IERC20(_usdc);
        referralGateway = _referralGateway;
        usdc.approve(_referralGateway, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                                SETTINGS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allows the owner to enable/disable a source chain to the list of allowed chains.
     * @param sourceChainSelector The chain selector of the source chain.
     */
    function toggleAllowedSourceChain(uint64 sourceChainSelector) external onlyOwner {
        require(sourceChainSelector != 0, TLDCcipReceiver__NotAllowedSource());
        bool enable = !isSourceChainAllowed[sourceChainSelector];
        isSourceChainAllowed[sourceChainSelector] = enable;
    }

    /**
     * @notice Allows the owner to enable/disable a sender to the list of allowed senders.
     * @param sender The address of the sender.
     */
    function toggleAllowedSender(address sender) external onlyOwner {
        require(sender != address(0), TLDCcipReceiver__NotAllowedSource());
        bool enable = !isSenderAllowed[sender];
        isSenderAllowed[sender] = enable;
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
        try this.processMessage(any2EvmMessage) {} catch (bytes memory err) {
            failedMessages.set(any2EvmMessage.messageId, uint256(ErrorCode.FAILED));
            messageContentsById[any2EvmMessage.messageId] = any2EvmMessage;
            emit OnMessageFailed(any2EvmMessage.messageId, err);
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
        onlySelf
        onlyAllowedSource(
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address))
        )
    {
        _ccipReceive(any2EvmMessage);
    }

    /**
     * @notice Allows the owner to retry a failed message in order to unblock the associated tokens.
     * @param messageId The unique identifier of the failed message
     * @dev This function is only callable by the contract owner
     * @dev It changes the status of the message from 'failed' to 'resolved' to prevent reentrancy
     * Todo: Try again the low level call to the referral gateway, this one is to be implemented completely in other PR
     */
    function retryFailedMessage(bytes32 messageId) external onlyOwner {
        require(
            failedMessages.get(messageId) == uint256(ErrorCode.FAILED),
            TLDCcipReceiver__MessageNotFailed(messageId)
        );
        failedMessages.set(messageId, uint256(ErrorCode.RESOLVED));

        Client.Any2EVMMessage memory message = messageContentsById[messageId];

        emit OnMessageRecovered(messageId);
    }

    /**
     * @notice Retrieves a paginated list of failed messages.
     * @param offset The index of the first failed message to return, enabling pagination by skipping a specified number of messages
     * @param limit The maximum number of failed messages to return, this is the size of the returned array
     * @return failedMessages. Array of `FailedMessage` struct, with a `messageId` and an `errorCode` (RESOLVED or FAILED)
     */
    function getFailedMessages(
        uint256 offset,
        uint256 limit
    ) external view returns (FailedMessage[] memory) {
        uint256 length = failedMessages.length();

        uint256 returnLength = (offset + limit > length) ? length - offset : limit;
        FailedMessage[] memory failedMessagesList = new FailedMessage[](returnLength);

        for (uint256 i; i < returnLength; ++i) {
            (bytes32 messageId, uint256 errorCode) = failedMessages.at(offset + i);
            failedMessagesList[i] = FailedMessage(messageId, ErrorCode(errorCode));
        }
        return failedMessagesList;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        // Low level call to the referral gateway
        (bool success, ) = referralGateway.call(any2EvmMessage.data);
        require(success, TLDCcipReceiver__CallFailed());
        emit OnMessageReceived(
            any2EvmMessage.messageId,
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address)),
            any2EvmMessage.data,
            any2EvmMessage.destTokenAmounts[0].amount
        );
    }
}
