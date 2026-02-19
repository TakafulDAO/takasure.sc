//SPDX-License-Identifier: GNU GPLv3

/**
 * @title SFAndIFCcipReceiver
 * @author Maikel Ordaz
 * @notice This contract will:
 *          - Interact with the CCIP pprotocol
 *          - Receive data from the Sender contract
 *          - Perform a call to the SFVault or IFVault with the data received
 *          - Deployed only in Arbitrum (One and Sepolia)
 */
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";

import {Client} from "ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract SFAndIFCcipReceiver is CCIPReceiver, Ownable2Step {
    using SafeERC20 for IERC20;
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;

    bytes4 private constant DEPOSIT_SELECTOR = bytes4(keccak256("deposit(uint256,address)"));

    IAddressManager private immutable addressManager;
    IERC20 private immutable underlying;

    mapping(uint64 chainSelector => mapping(address sender => bool)) public isSenderAllowedByChain;
    mapping(bytes32 messageId => Client.Any2EVMMessage message) public messageContentsById;
    mapping(address user => Client.Any2EVMMessage message) public messageByUser;
    mapping(address user => bytes32 messageId) public messageIdByUser;
    mapping(bytes32 messageId => address user) public userByMessageId;
    mapping(address user => bytes32[] messageIds) private failedMessageIdsByUser;

    EnumerableMap.Bytes32ToUintMap internal failedMessages;

    enum StatusCode {
        FAILED, // Messages that receives this contract, but is not able to make the low level call
        RESOLVED, // Failed messages that are successfull after retry
        RECOVERED // Failed messages the user recover the tokens
    }

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    struct FailedMessage {
        bytes32 messageId;
        StatusCode statusCode;
    }

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
    event OnMessageDecoded(bytes32 indexed messageId, string protocolName, address indexed user);

    error SFAndIFCcipReceiver__NotZeroAddress();
    error SFAndIFCcipReceiver__NotAllowedSource();
    error SFAndIFCcipReceiver__OnlySelf();
    error SFAndIFCcipReceiver__CallFailed(bytes reason);
    error SFAndIFCcipReceiver__VaultNotConfigured(string protocolName);
    error SFAndIFCcipReceiver__InvalidProtocolCallDataLength(uint256 length);
    error SFAndIFCcipReceiver__InvalidProtocolCallSelector(bytes4 selector);
    error SFAndIFCcipReceiver__InvalidMessageData();
    error SFAndIFCcipReceiver__InvalidDestTokenAmountsLength(uint256 length);
    error SFAndIFCcipReceiver__InvalidDestTokenAddress(address token);
    error SFAndIFCcipReceiver__MessageNotFailed(bytes32 messageId);
    error SFAndIFCcipReceiver__NoFailedMessages(address user);
    error SFAndIFCcipReceiver__MessageUserMismatch(address user, bytes32 messageId);
    error SFAndIFCcipReceiver__NotAuthorized();

    modifier onlyAllowedSource(uint64 _sourceChainSelector, address _sender) {
        require(isSenderAllowedByChain[_sourceChainSelector][_sender], SFAndIFCcipReceiver__NotAllowedSource());
        _;
    }

    modifier onlyOwnerOrUser(address user) {
        require(msg.sender == owner() || msg.sender == user, SFAndIFCcipReceiver__NotAuthorized());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the receiver with immutable dependencies.
     * @param _addressManager Address resolver for protocol contracts.
     * @param _router CCIP router address authorized to call `ccipReceive`.
     * @param _underlying The underlying token used for inbound bridged amounts.
     */
    constructor(IAddressManager _addressManager, address _router, address _underlying)
        CCIPReceiver(_router)
        Ownable(msg.sender)
    {
        require(
            address(_addressManager) != address(0) && _router != address(0) && _underlying != address(0),
            SFAndIFCcipReceiver__NotZeroAddress()
        );
        underlying = IERC20(_underlying);
        addressManager = _addressManager;
    }

    /*//////////////////////////////////////////////////////////////
                                SETTINGS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allows the owner to enable/disable a sender.
     * @param chainSelector source chain
     * @param sender The address of the sender contract.
     * @custom:invariant Post-call, sender allowlist state flips for `(chainSelector, sender)`.
     */
    function toggleAllowedSender(uint64 chainSelector, address sender) external onlyOwner {
        require(sender != address(0), SFAndIFCcipReceiver__NotAllowedSource());
        bool enable = !isSenderAllowedByChain[chainSelector][sender];
        isSenderAllowedByChain[chainSelector][sender] = enable;
    }

    /*//////////////////////////////////////////////////////////////
                            RECEIVE MESSAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice CCIP router calls this function. Should never revert, errors are handled internally
     * @param any2EvmMessage The message to process
     * @dev Only router can call
     * @custom:invariant Message-processing failures are persisted into `failedMessages` with status `FAILED`.
     * @custom:invariant On failure, user/message indexing mappings are updated for recovery flows.
     */
    function ccipReceive(Client.Any2EVMMessage calldata any2EvmMessage)
        external
        override
        onlyRouter
        onlyAllowedSource(any2EvmMessage.sourceChainSelector, abi.decode(any2EvmMessage.sender, (address)))
    {
        try this.processMessage(any2EvmMessage) {}
        catch (bytes memory reason) {
            // Save the message by user for easy access
            address user = _getUserAddress(any2EvmMessage.data);
            if (!failedMessages.contains(any2EvmMessage.messageId)) {
                failedMessageIdsByUser[user].push(any2EvmMessage.messageId);
            }

            failedMessages.set(any2EvmMessage.messageId, uint256(StatusCode.FAILED));
            messageContentsById[any2EvmMessage.messageId] = any2EvmMessage;
            messageByUser[user] = any2EvmMessage;
            messageIdByUser[user] = any2EvmMessage.messageId;
            userByMessageId[any2EvmMessage.messageId] = user;

            emit OnMessageFailed(any2EvmMessage.messageId, reason, user);
            return;
        }
    }

    /**
     * @notice It process the message received from the CCIP protocol.
     * @param any2EvmMessage Received CCIP message.
     * @custom:invariant Can only be called by this contract (`msg.sender == address(this)`).
     */
    function processMessage(Client.Any2EVMMessage calldata any2EvmMessage)
        external
        onlyAllowedSource(any2EvmMessage.sourceChainSelector, abi.decode(any2EvmMessage.sender, (address)))
    {
        require(msg.sender == address(this), SFAndIFCcipReceiver__OnlySelf());
        _ccipReceive(any2EvmMessage);
    }

    /**
     * @notice Allows the owner to retry the latest failed message in order to unblock the associated tokens.
     * @param user The user which message failed
     * @dev This function is only callable by the user or contract owner
     * @dev It changes the status of the message from 'failed' to 'resolved'
     * @custom:invariant Delegates to ID-based retry using the latest message whose status is still `FAILED`.
     */
    function retryFailedMessage(address user) external onlyOwnerOrUser(user) {
        retryFailedMessageById(user, _getLatestFailedMessageId(user));
    }

    /**
     * @notice Allows the owner to retry a specific failed message.
     * @param user The user linked to the failed message.
     * @param messageId The failed message ID to retry.
     * @custom:invariant On success, `failedMessages[messageId]` transitions from `FAILED` to `RESOLVED`.
     */
    function retryFailedMessageById(address user, bytes32 messageId) public onlyOwnerOrUser(user) {
        (Client.Any2EVMMessage memory message,) = _getUserMessage(user, messageId);
        (string memory _protocolName, bytes memory _protocolCallData) = _decodeMessageData(message.data);
        uint256 _tokenAmount = _getValidatedTokenAmount(message);

        (bool _success, bytes memory _returnData) = _callVault(_protocolName, _protocolCallData, _tokenAmount);

        require(_success, SFAndIFCcipReceiver__CallFailed(_returnData));

        failedMessages.set(messageId, uint256(StatusCode.RESOLVED));
        emit OnMessageRecovered(messageId);
    }

    /**
     * @notice An emergency function to allow a user to recover their tokens in case of a failed message.
     * @param user The user which message failed
     * @dev This function is only callable by the user or the contract owner
     * @custom:invariant Delegates to ID-based recovery using the latest message whose status is still `FAILED`.
     */
    function recoverTokens(address user) external onlyOwnerOrUser(user) {
        recoverTokensById(user, _getLatestFailedMessageId(user));
    }

    /**
     * @notice Allows the owner or user to recover a specific failed message amount.
     * @param user The user linked to the failed message.
     * @param messageId The failed message ID to recover.
     * @custom:invariant On success, `failedMessages[messageId]` transitions from `FAILED` to `RECOVERED`.
     * @custom:invariant On success, exactly the validated bridged token amount is transferred to `user`.
     */
    function recoverTokensById(address user, bytes32 messageId) public onlyOwnerOrUser(user) {
        (Client.Any2EVMMessage memory message,) = _getUserMessage(user, messageId);
        uint256 _tokenAmount = _getValidatedTokenAmount(message);

        failedMessages.set(messageId, uint256(StatusCode.RECOVERED));
        underlying.safeTransfer(user, _tokenAmount);

        emit OnTokensRecovered(user, _tokenAmount);
    }

    /**
     * @notice Returns the full list of failed-message IDs ever associated with a user.
     * @dev IDs may include messages already resolved/recovered; check status in failedMessages map.
     * @param user User address to inspect.
     * @return messageIds Ordered list (append order) of failed-message IDs seen for `user`.
     * @custom:invariant Returned list order is stable and reflects insertion chronology.
     */
    function getFailedMessageIdsByUser(address user) external view returns (bytes32[] memory) {
        return failedMessageIdsByUser[user];
    }

    /**
     * @notice Retrieves a paginated list of failed messages.
     * @param offset The index of the first failed message to return, enabling pagination by skipping a specified number of messages
     * @param limit The maximum number of failed messages to return, this is the size of the returned array
     * @return failedMessages. Array of `FailedMessage` struct, with a `messageId` and an `statusCode` (RESOLVED or FAILED)
     * @custom:invariant Function never underflows on out-of-range `offset`; returns empty list when `offset >= length`.
     */
    function getFailedMessages(uint256 offset, uint256 limit) external view returns (FailedMessage[] memory) {
        uint256 length = failedMessages.length();
        if (offset >= length || limit == 0) return new FailedMessage[](0);

        uint256 remaining = length - offset;
        uint256 returnLength = limit > remaining ? remaining : limit;

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

    /**
     * @notice Core CCIP receive handler invoked from `processMessage`.
     * @param any2EvmMessage Decoded CCIP message.
     * @custom:invariant Accepts validated token payloads and routes by protocol name.
     * @custom:invariant Emits `OnMessageReceived` only after successful low-level vault call.
     */
    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        (string memory _protocolName, bytes memory _protocolCallData) = _decodeMessageData(any2EvmMessage.data);
        uint256 _tokenAmount = _getValidatedTokenAmount(any2EvmMessage);

        address _user = _getUserAddress(any2EvmMessage.data);

        emit OnMessageDecoded(any2EvmMessage.messageId, _protocolName, _user);

        (bool _success, bytes memory _returnData) = _callVault(_protocolName, _protocolCallData, _tokenAmount);

        if (_success) {
            emit OnMessageReceived(
                any2EvmMessage.messageId,
                any2EvmMessage.sourceChainSelector,
                abi.decode(any2EvmMessage.sender, (address)),
                _protocolCallData,
                _tokenAmount
            );
        } else {
            revert SFAndIFCcipReceiver__CallFailed(_returnData);
        }
    }

    /**
     * @notice Safely extracts user address from encoded message payload.
     * @param _data Message data expected as `abi.encode(protocolName, protocolCallData)`.
     * @return userAddr_ Decoded user receiver address, or `address(0)` when payload is malformed.
     * @custom:invariant Function never reverts on malformed payload; returns `address(0)` instead.
     */
    function _getUserAddress(bytes memory _data) internal pure returns (address userAddr_) {
        uint256 dataLength = _data.length;
        // abi.encode(string, bytes) minimum payload is 4 words
        if (dataLength < 0x80) return address(0);

        uint256 bytesOffset;

        assembly {
            // `_data` points to length; payload words start at `_data + 0x20`.
            // In `abi.encode(string, bytes)`, the second head word lives at payload offset `0x20`.
            // Reading from `_data + 0x40` yields that second head word.
            let bytesOffsetWordPtr := add(_data, 0x40)
            // Load the dynamic-bytes offset (relative to payload start) into `bytesOffset`.
            bytesOffset := mload(bytesOffsetWordPtr)
        }

        // Dynamic-bytes length word must be inside bounds
        if (bytesOffset > dataLength - 0x20) return address(0);

        uint256 protocolCallDataLength;
        uint256 protocolCallDataStart;

        assembly {
            // Move pointer from length slot to start of ABI payload.
            let payloadStart := add(_data, 0x20)
            // Compute pointer to dynamic-bytes length slot: payload start + dynamic offset.
            let protocolCallDataLengthPos := add(payloadStart, bytesOffset)
            // Read length of nested `protocolCallData`.
            protocolCallDataLength := mload(protocolCallDataLengthPos)
            // Nested bytes body starts right after its length word.
            protocolCallDataStart := add(protocolCallDataLengthPos, 0x20)
        }

        //  Bytes data itself must be fully inside bounds
        if (protocolCallDataLength > dataLength - bytesOffset - 0x20) return address(0);
        // Need selector (4 bytes) + uint256 (32 bytes) + address slot (32 bytes)
        if (protocolCallDataLength < 0x44) return address(0);

        // `protocolCallData` expected: deposit(uint256 assets, address receiver)
        // receiver starts at offset 0x24 (4-byte selector + first 32-byte arg)
        assembly {
            // Read 32-byte word at receiver offset and assign to `userAddr_`.
            // Solidity will keep the low 20 bytes as the canonical address value.
            userAddr_ := mload(add(protocolCallDataStart, 0x24))
        }
    }

    /**
     * @notice Resolves destination vault address by protocol name.
     * @param _protocolName Protocol key expected in AddressManager.
     * @return vaultAddr_ Resolved vault address from AddressManager.
     * @custom:invariant Returned vault address is non-zero and contains contract code.
     */
    function _getVaultAddress(string memory _protocolName) internal view returns (address vaultAddr_) {
        vaultAddr_ = addressManager.getProtocolAddressByName(_protocolName).addr;

        require(
            vaultAddr_ != address(0) && vaultAddr_.code.length > 0,
            SFAndIFCcipReceiver__VaultNotConfigured(_protocolName)
        );
    }

    /**
     * @notice Decodes sender payload into protocol name and nested protocol call data.
     * @param _data Encoded payload sent by CCIP sender.
     * @return protocolName_ Protocol name used for vault resolution.
     * @return protocolCallData_ Nested calldata intended for vault execution.
     * @custom:invariant Reverts if `_data` is not encoded as `abi.encode(string,bytes)`.
     */
    function _decodeMessageData(bytes memory _data)
        internal
        pure
        returns (string memory protocolName_, bytes memory protocolCallData_)
    {
        uint256 dataLength = _data.length;
        // abi.encode(string, bytes) has 2 head words + 2 tail lengths at minimum.
        require(dataLength >= 0x80, SFAndIFCcipReceiver__InvalidMessageData());

        uint256 protocolNameOffset;
        uint256 protocolCallDataOffset;
        uint256 protocolNameLength;
        uint256 protocolNameStart;
        uint256 protocolCallDataLength;
        uint256 protocolCallDataStart;

        assembly {
            // Read first head word (dynamic string offset) from payload offset 0x00.
            protocolNameOffset := mload(add(_data, 0x20))
            // Read second head word (dynamic bytes offset) from payload offset 0x20.
            protocolCallDataOffset := mload(add(_data, 0x40))
        }

        // Dynamic string and bytes length words must sit within payload bounds.
        require(protocolNameOffset <= dataLength - 0x20, SFAndIFCcipReceiver__InvalidMessageData());
        require(protocolCallDataOffset <= dataLength - 0x20, SFAndIFCcipReceiver__InvalidMessageData());

        bytes memory protocolNameBytes;

        assembly {
            // Move pointer from length slot to start of ABI payload.
            let payloadStart := add(_data, 0x20)
            // Compute pointer to nested-string length word.
            let protocolNameLengthPos := add(payloadStart, protocolNameOffset)
            // Load nested string byte length.
            protocolNameLength := mload(protocolNameLengthPos)
            // Nested string bytes start immediately after that length word.
            protocolNameStart := add(protocolNameLengthPos, 0x20)
            // Compute pointer to nested-bytes length word.
            let protocolCallDataLengthPos := add(payloadStart, protocolCallDataOffset)
            // Load nested calldata byte length.
            protocolCallDataLength := mload(protocolCallDataLengthPos)
            // Nested calldata bytes start immediately after that length word.
            protocolCallDataStart := add(protocolCallDataLengthPos, 0x20)
        }

        // Nested string bytes must be fully contained in `_data`.
        require(protocolNameLength <= dataLength - protocolNameOffset - 0x20, SFAndIFCcipReceiver__InvalidMessageData());

        protocolNameBytes = new bytes(protocolNameLength);
        if (protocolNameLength > 0) {
            assembly {
                // Destination pointer: first byte of allocated `protocolNameBytes` body.
                let dst := add(protocolNameBytes, 0x20)
                // Source pointer: first byte of nested string inside `_data`.
                let src := protocolNameStart
                // End pointer for copy loop.
                let end := add(src, protocolNameLength)
                // Copy in 32-byte chunks; trailing partial word is copied once as padded word.
                for {} lt(src, end) {
                    src := add(src, 0x20)
                    dst := add(dst, 0x20)
                } { mstore(dst, mload(src)) }
            }
        }
        protocolName_ = string(protocolNameBytes);

        // Nested calldata bytes must be fully contained in `_data`.
        require(
            protocolCallDataLength <= dataLength - protocolCallDataOffset - 0x20,
            SFAndIFCcipReceiver__InvalidMessageData()
        );

        protocolCallData_ = new bytes(protocolCallDataLength);
        if (protocolCallDataLength == 0) return (protocolName_, protocolCallData_);

        assembly {
            // Destination pointer: first byte of allocated `protocolCallData_` body.
            let dst := add(protocolCallData_, 0x20)
            // Source pointer: first byte of nested calldata inside `_data`.
            let src := protocolCallDataStart
            // End pointer for copy loop.
            let end := add(src, protocolCallDataLength)
            // Copy in 32-byte chunks; trailing partial word is copied once as padded word.
            for {} lt(src, end) {
                src := add(src, 0x20)
                dst := add(dst, 0x20)
            } { mstore(dst, mload(src)) }
        }
    }

    /**
     * @notice Fetches and validates a failed message for a specific user and message ID.
     * @param _user User expected to own the failed message.
     * @param _messageId Failed message ID to fetch.
     * @return message_ Stored CCIP message payload.
     * @return messageId_ Echoed message ID.
     * @custom:invariant Reverts unless message is associated with `_user` and currently marked `FAILED`.
     */
    function _getUserMessage(address _user, bytes32 _messageId)
        internal
        view
        returns (Client.Any2EVMMessage memory message_, bytes32 messageId_)
    {
        messageId_ = _messageId;
        require(userByMessageId[messageId_] == _user, SFAndIFCcipReceiver__MessageUserMismatch(_user, messageId_));
        require(failedMessages.contains(messageId_), SFAndIFCcipReceiver__MessageNotFailed(messageId_));
        require(
            failedMessages.get(messageId_) == uint256(StatusCode.FAILED),
            SFAndIFCcipReceiver__MessageNotFailed(messageId_)
        );
        message_ = messageContentsById[messageId_];
    }

    /**
     * @notice Finds the most recent message ID for a user that is still in `FAILED` state.
     * @param _user User to inspect.
     * @return messageId_ Latest failed message ID.
     * @custom:invariant Reverts if user has no currently-failed message.
     */
    function _getLatestFailedMessageId(address _user) internal view returns (bytes32 messageId_) {
        bytes32[] storage messageIds = failedMessageIdsByUser[_user];
        uint256 length = messageIds.length;
        require(length > 0, SFAndIFCcipReceiver__NoFailedMessages(_user));

        for (uint256 i = length; i > 0; --i) {
            bytes32 currentMessageId = messageIds[i - 1];
            if (failedMessages.contains(currentMessageId)) {
                uint256 statusCode = failedMessages.get(currentMessageId);
                if (statusCode == uint256(StatusCode.FAILED)) {
                    return currentMessageId;
                }
            }
        }

        revert SFAndIFCcipReceiver__NoFailedMessages(_user);
    }

    /**
     * @notice Executes validated protocol call against the resolved vault.
     * @param _protocolName Protocol name selecting destination vault.
     * @param _protocolCallData Nested function calldata to execute.
     * @param _tokenAmount underlying token amount to approve for vault pull.
     * @return success_ Whether the low-level call succeeded.
     * @return returnData_ Return or revert bytes from vault call.
     * @custom:invariant underlying token allowance granted to vault is always reset to zero before function returns.
     */
    function _callVault(string memory _protocolName, bytes memory _protocolCallData, uint256 _tokenAmount)
        internal
        returns (bool success_, bytes memory returnData_)
    {
        _validateProtocolCallData(_protocolCallData);

        address _vault = _getVaultAddress(_protocolName);

        underlying.forceApprove(_vault, _tokenAmount);
        (success_, returnData_) = _vault.call(_protocolCallData);
        underlying.forceApprove(_vault, 0);
    }

    /**
     * @notice Validates inbound token payload shape and token address, then returns amount.
     * @param _message Any2EVM message carrying token transfer metadata.
     * @return tokenAmount_ Validated token amount.
     * @custom:invariant Reverts unless exactly one destination token amount exists and token is underlying.
     */
    function _getValidatedTokenAmount(Client.Any2EVMMessage memory _message)
        internal
        view
        returns (uint256 tokenAmount_)
    {
        uint256 _length = _message.destTokenAmounts.length;
        require(_length == 1, SFAndIFCcipReceiver__InvalidDestTokenAmountsLength(_length));

        Client.EVMTokenAmount memory _tokenAmount = _message.destTokenAmounts[0];
        require(
            _tokenAmount.token == address(underlying), SFAndIFCcipReceiver__InvalidDestTokenAddress(_tokenAmount.token)
        );

        tokenAmount_ = _tokenAmount.amount;
    }

    /**
     * @notice Validates nested protocol calldata shape and function selector.
     * @param _protocolCallData Nested calldata from the CCIP payload.
     * @custom:invariant Reverts unless calldata selector is exactly `deposit(uint256,address)`.
     */
    function _validateProtocolCallData(bytes memory _protocolCallData) internal pure {
        uint256 _length = _protocolCallData.length;
        require(_length >= 4, SFAndIFCcipReceiver__InvalidProtocolCallDataLength(_length));

        bytes4 _selector = bytes4(
            (uint32(uint8(_protocolCallData[0])) << 24) | (uint32(uint8(_protocolCallData[1])) << 16)
                | (uint32(uint8(_protocolCallData[2])) << 8) | uint32(uint8(_protocolCallData[3]))
        );

        require(_selector == DEPOSIT_SELECTOR, SFAndIFCcipReceiver__InvalidProtocolCallSelector(_selector));
    }
}
