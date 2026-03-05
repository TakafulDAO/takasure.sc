// SPDX-License-Identifier: GNU GPLv3
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRouterClient} from "ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "ccip/contracts/src/v0.8/ccip/libraries/Client.sol";

contract CCIPTestERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function test() external {}
}

contract CCIPTestRouter is IRouterClient {
    using SafeERC20 for IERC20;

    uint256 public configuredFee;
    bool public supported = true;
    bytes32 public nextMessageId = bytes32(uint256(1));

    uint64 public lastDestinationChainSelector;
    bytes public lastReceiver;
    bytes public lastData;
    address public lastFeeToken;
    address public lastToken;
    uint256 public lastTokenAmount;
    address public lastCaller;

    function setFee(uint256 newFee) external {
        configuredFee = newFee;
    }

    function setSupported(bool isSupported) external {
        supported = isSupported;
    }

    function setNextMessageId(bytes32 messageId) external {
        nextMessageId = messageId;
    }

    function isChainSupported(uint64) external view returns (bool supported_) {
        return supported;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external view returns (uint256 fee) {
        return configuredFee;
    }

    function ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32)
    {
        lastCaller = msg.sender;
        lastDestinationChainSelector = destinationChainSelector;
        lastReceiver = message.receiver;
        lastData = message.data;
        lastFeeToken = message.feeToken;

        if (configuredFee > 0 && message.feeToken != address(0)) {
            IERC20(message.feeToken).safeTransferFrom(msg.sender, address(this), configuredFee);
        }

        if (message.tokenAmounts.length > 0) {
            lastToken = message.tokenAmounts[0].token;
            lastTokenAmount = message.tokenAmounts[0].amount;
        }

        for (uint256 i; i < message.tokenAmounts.length; ++i) {
            IERC20(message.tokenAmounts[i].token)
                .safeTransferFrom(msg.sender, address(this), message.tokenAmounts[i].amount);
        }

        bytes32 messageId = nextMessageId;
        nextMessageId = bytes32(uint256(messageId) + 1);
        return messageId;
    }

    function test() external {}
}

contract CCIPTestVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    bool public shouldRevert;

    address public lastCaller;
    address public lastReceiver;
    uint256 public lastAssets;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        if (shouldRevert) revert("CCIPTestVault__ForcedRevert");

        lastCaller = msg.sender;
        lastReceiver = receiver;
        lastAssets = assets;

        usdc.safeTransferFrom(msg.sender, address(this), assets);
        shares = assets;
    }

    function test() external {}
}
