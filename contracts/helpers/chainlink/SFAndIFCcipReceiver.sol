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
import {Protocols} from "contracts/helpers/chainlink/Protocols.sol";

import {Client} from "ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract SFAndIFCcipReceiver is CCIPReceiver, Ownable2Step {
    using SafeERC20 for IERC20;
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;

    IAddressManager private immutable addressManager;
    IERC20 private immutable usdc;

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
    event OnMessageDecoded(bytes32 indexed messageId, uint256 indexed protocolToCall, address indexed user);

    error SFAndIFCcipReceiver__NotZeroAddress();
    error SFAndIFCcipReceiver__NotAllowedSource();
    error SFAndIFCcipReceiver__OnlySelf();
    error SFAndIFCcipReceiver__InvalidProtocol(uint256 protocolToCall);
    error SFAndIFCcipReceiver__CallFailed(bytes reason);
    error SFAndIFCcipReceiver__VaultNotConfigured(uint256 protocolToCall);
    error SFAndIFCcipReceiver__MessageNotFailed(bytes32 messageId);
    error SFAndIFCcipReceiver__NotAuthorized();

    /**
     * @param _sourceChainSelector Identify the source blockchain
     * @param _sender Identify the sender contract in the source blockchain
     */
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
     * @param _addressManager TLD address resolver
     * @param _router The address of the router contract.
     * @param _usdc The address of the usdc contract.
     */
    constructor(IAddressManager _addressManager, address _router, address _usdc)
        CCIPReceiver(_router)
        Ownable(msg.sender)
    {
        require(
            address(_addressManager) != address(0) && _router != address(0) && _usdc != address(0),
            SFAndIFCcipReceiver__NotZeroAddress()
        );
        usdc = IERC20(_usdc);
        addressManager = _addressManager;
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
     */
    function ccipReceive(Client.Any2EVMMessage calldata any2EvmMessage)
        external
        override
        onlyRouter
        onlyAllowedSource(any2EvmMessage.sourceChainSelector, abi.decode(any2EvmMessage.sender, (address)))
    {
        try this.processMessage(any2EvmMessage) {}
        catch (bytes memory reason) {
            failedMessages.set(any2EvmMessage.messageId, uint256(StatusCode.FAILED));
            messageContentsById[any2EvmMessage.messageId] = any2EvmMessage;

            // Save the message by user for easy access
            address user = _getUserAddress(any2EvmMessage.data);
            messageByUser[user] = any2EvmMessage;
            messageIdByUser[user] = any2EvmMessage.messageId;

            emit OnMessageFailed(any2EvmMessage.messageId, reason, user);
            return;
        }
    }

    /**
     * @notice It process the message received from the CCIP protocol.
     * @param any2EvmMessage Received CCIP message.
     */
    function processMessage(Client.Any2EVMMessage calldata any2EvmMessage)
        external
        onlyAllowedSource(any2EvmMessage.sourceChainSelector, abi.decode(any2EvmMessage.sender, (address)))
    {
        require(msg.sender == address(this), SFAndIFCcipReceiver__OnlySelf());
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
        (uint256 _protocolToCall, bytes memory _protocolCallData) = _decodeMessageData(message.data);

        (bool _success, bytes memory _returnData) =
            _callVault(_protocolToCall, _protocolCallData, message.destTokenAmounts[0].amount);

        require(_success, SFAndIFCcipReceiver__CallFailed(_returnData));

        failedMessages.set(messageId, uint256(StatusCode.RESOLVED));
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
        usdc.safeTransfer(user, message.destTokenAmounts[0].amount);

        emit OnTokensRecovered(user, message.destTokenAmounts[0].amount);
    }

    /**
     * @notice Retrieves a paginated list of failed messages.
     * @param offset The index of the first failed message to return, enabling pagination by skipping a specified number of messages
     * @param limit The maximum number of failed messages to return, this is the size of the returned array
     * @return failedMessages. Array of `FailedMessage` struct, with a `messageId` and an `statusCode` (RESOLVED or FAILED)
     */
    function getFailedMessages(uint256 offset, uint256 limit) external view returns (FailedMessage[] memory) {
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
        (uint256 _protocolToCall, bytes memory _protocolCallData) = _decodeMessageData(any2EvmMessage.data);
        require(
            _protocolToCall == Protocols.SAVE_VAULT || _protocolToCall == Protocols.INVEST_VAULT,
            SFAndIFCcipReceiver__InvalidProtocol(_protocolToCall)
        );

        address _user = _getUserAddress(any2EvmMessage.data);

        emit OnMessageDecoded(any2EvmMessage.messageId, _protocolToCall, _user);

        (bool _success, bytes memory _returnData) =
            _callVault(_protocolToCall, _protocolCallData, any2EvmMessage.destTokenAmounts[0].amount);

        if (_success) {
            emit OnMessageReceived(
                any2EvmMessage.messageId,
                any2EvmMessage.sourceChainSelector,
                abi.decode(any2EvmMessage.sender, (address)),
                _protocolCallData,
                any2EvmMessage.destTokenAmounts[0].amount
            );
        } else {
            revert SFAndIFCcipReceiver__CallFailed(_returnData);
        }
    }

    function _getUserAddress(bytes memory _data) internal pure returns (address userAddr_) {
        (, bytes memory _protocolCallData) = _decodeMessageData(_data);
        if (_protocolCallData.length < 0x44) return address(0);

        // `_protocolCallData` is expected to be: deposit(uint256 assets, address receiver)
        // receiver starts at: bytes(4 selector + 32 first arg) = offset 0x24 from data start
        assembly {
            userAddr_ := mload(add(_protocolCallData, 0x44))
        }
    }

    function _getVaultAddress(uint256 _protocolToCall) internal view returns (address vaultAddr_) {
        if (_protocolToCall == Protocols.SAVE_VAULT) {
            vaultAddr_ = addressManager.getProtocolAddressByName("PROTOCOL__SF_VAULT").addr;
        } else if (_protocolToCall == Protocols.INVEST_VAULT) {
            vaultAddr_ = addressManager.getProtocolAddressByName("PROTOCOL__IF_VAULT").addr;
        }

        require(
            vaultAddr_ != address(0) && vaultAddr_.code.length > 0,
            SFAndIFCcipReceiver__VaultNotConfigured(_protocolToCall)
        );
    }

    function _decodeMessageData(bytes memory _data)
        internal
        pure
        returns (uint256 protocolToCall_, bytes memory protocolCallData_)
    {
        // Data format from sender: abi.encode(protocolToCall, protocolCallData)
        return abi.decode(_data, (uint256, bytes));
    }

    function _getUserMessage(address _user)
        internal
        view
        returns (Client.Any2EVMMessage memory message_, bytes32 messageId_)
    {
        messageId_ = messageIdByUser[_user];
        require(failedMessages.contains(messageId_), SFAndIFCcipReceiver__MessageNotFailed(messageId_));
        require(
            failedMessages.get(messageId_) == uint256(StatusCode.FAILED),
            SFAndIFCcipReceiver__MessageNotFailed(messageId_)
        );
        message_ = messageContentsById[messageId_];
    }

    function _callVault(uint256 _protocolToCall, bytes memory _protocolCallData, uint256 _tokenAmount)
        internal
        returns (bool success_, bytes memory returnData_)
    {
        address _vault = _getVaultAddress(_protocolToCall);

        usdc.approve(_vault, _tokenAmount);
        return _vault.call(_protocolCallData);
    }
}
