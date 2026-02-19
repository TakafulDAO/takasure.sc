//SPDX-License-Identifier: GNU GPLv3

/**
 * @title SFAndIFCcipSender
 * @author Maikel Ordaz
 * @notice This contract will:
 *          - Interact with the CCIP protocol
 *          - Encode the data to send
 *          - Send data to the Receiver contract
 *          - Deployed in Avax (Mainnet and Fuji), Base (Mainnet and Sepolia), Ethereum (Mainnet and Sepolia),
 *            Optimism (Mainnet and Sepolia), Polygon (Mainnet and Amoy)
 * @dev Upgradeable contract with UUPS pattern
 */

pragma solidity 0.8.28;

import {IRouterClient} from "ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {Client} from "ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Protocols} from "contracts/helpers/chainlink/Protocols.sol";

/// @custom:oz-upgrades-from contracts/version_previous_contracts/SFAndIFCcipSenderV1.sol:SFAndIFCcipSenderV1
contract SFAndIFCcipSender is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;

    IRouterClient private router;
    IERC20 private linkToken;
    IERC20 private underlying;

    uint64 public destinationChainSelector; // Only Arbitrum (One, Sepolia)
    address public receiverContract;

    struct MessageBuild {
        uint256 protocolToCall;
        uint256 amount;
        uint256 gasLimit;
        address userAddr;
    }

    /*//////////////////////////////////////////////////////////////
                            EVENTS & ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnReceiverContractSet(address oldReceiverContract, address newReceiverContract);
    event OnTokensTransferred(
        bytes32 indexed messageId, uint256 indexed tokenAmount, uint256 indexed fees, address userAddr
    );

    error SFAndIFCcipSender__AddressZeroNotAllowed();
    error SFAndIFCcipSender__ZeroTransferNotAllowed();
    error SFAndIFCcipSender__InvalidProtocol(uint256 protocolToCall);
    error SFAndIFCcipSender__NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error SFAndIFCcipSender__NothingToWithdraw();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier notZeroAddress(address addressToCheck) {
        require(addressToCheck != address(0), SFAndIFCcipSender__AddressZeroNotAllowed());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the CCIP sender instance.
     * @param _router The address of the router contract.
     * @param _link The address of the link contract.
     * @param _underlying The address of the underlying token to bridge (USDC).
     * @param _receiverContract Receiver contract in the destination blockchain. This will be the only receiver
     * @param _chainSelector The chain selector of the destination chain. Only Arbitrum (One, Sepolia) is supported.
     * @param _owner Admin address.
     */
    function initialize(
        address _router,
        address _link,
        address _underlying,
        address _receiverContract,
        uint64 _chainSelector,
        address _owner
    ) external initializer {
        require(
            _router != address(0) && _link != address(0) && _underlying != address(0)
                && _receiverContract != address(0),
            SFAndIFCcipSender__AddressZeroNotAllowed()
        );

        __UUPSUpgradeable_init();
        __Ownable2Step_init();
        __Ownable_init(_owner);

        router = IRouterClient(_router);
        linkToken = IERC20(_link);
        underlying = IERC20(_underlying);

        receiverContract = _receiverContract;
        destinationChainSelector = _chainSelector;

        emit OnReceiverContractSet(address(0), _receiverContract);
    }

    /*//////////////////////////////////////////////////////////////
                                SETTINGS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the address of the receiver contract.
     * @dev The first receiver will be the PrejoinModule. When the DAO is launched we change this to the EntryModule.
     * @param _receiverContract New receiver contract address.
     * @custom:invariant On success, `receiverContract` is non-zero and equals `_receiverContract`.
     */
    function setReceiverContract(address _receiverContract) external onlyOwner notZeroAddress(_receiverContract) {
        address oldReceiverContract = receiverContract;
        receiverContract = _receiverContract;

        emit OnReceiverContractSet(oldReceiverContract, receiverContract);
    }

    /*//////////////////////////////////////////////////////////////
                                PAYMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transfer tokens to receiver contract on the destination chain.
     * @dev Revert if this contract dont have sufficient LINK balance to pay for the fees.
     * @param protocolToCall The protocol to call in the destination chain. 0x01 for Save Fund, 0x02 for Investment Fund.
     * @param amountToTransfer token amount to transfer to the receiver contract in the destination chain.
     * @param gasLimit gas allowed by the user to be the maximum spend in the destination blockchain by the CCIP protocol
     * @param userAddr The address of the user wanting to participate in the Save Fund or Investment Fund use case.
     * @return messageId The ID of the message that was sent.
     * @custom:invariant On success, message payload always encodes protocol + `deposit(uint256,address)` call data.
     * @custom:invariant On success, both LINK and underlying router allowances are reset to zero at the end of execution.
     */
    function sendMessage(uint256 protocolToCall, uint256 amountToTransfer, uint256 gasLimit, address userAddr)
        external
        notZeroAddress(userAddr)
        returns (bytes32 messageId)
    {
        require(
            protocolToCall == Protocols.SAVE_VAULT || protocolToCall == Protocols.INVEST_VAULT,
            SFAndIFCcipSender__InvalidProtocol(protocolToCall)
        );
        require(amountToTransfer > 0, SFAndIFCcipSender__ZeroTransferNotAllowed());

        Client.EVM2AnyMessage memory message = _setup({
            _protocolToCall: protocolToCall,
            _amountToTransfer: amountToTransfer,
            _gasLimit: gasLimit,
            _userAddr: userAddr
        });

        uint256 ccipFees = _feeChecks(message);

        messageId = _sendMessage({
            _userAddr: userAddr, _amountToTransfer: amountToTransfer, _ccipFees: ccipFees, _message: message
        });
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency function to withdraw all Link tokens.
     * @param beneficiary The address to which the tokens will be sent.
     * @custom:invariant On success, this contract LINK balance becomes zero.
     */
    function withdrawLink(address beneficiary) external onlyOwner notZeroAddress(beneficiary) {
        // Retrieve the balance of this contract
        uint256 amount = linkToken.balanceOf(address(this));

        require(amount > 0, SFAndIFCcipSender__NothingToWithdraw());

        linkToken.safeTransfer(beneficiary, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Builds the complete CCIP message from user-level parameters.
     * @param _protocolToCall Protocol flag indicating target vault type.
     * @param _amountToTransfer Amount of underlying token to transfer cross-chain.
     * @param _gasLimit Gas limit requested for destination execution.
     * @param _userAddr Receiver/user address for vault deposit.
     * @return _message Encoded EVM2AnyMessage ready for fee estimation/sending.
     * @custom:invariant Returned message contains exactly one token transfer amount (underlying).
     */
    function _setup(uint256 _protocolToCall, uint256 _amountToTransfer, uint256 _gasLimit, address _userAddr)
        internal
        view
        returns (Client.EVM2AnyMessage memory _message)
    {
        MessageBuild memory messageBuild = MessageBuild({
            protocolToCall: _protocolToCall, amount: _amountToTransfer, gasLimit: _gasLimit, userAddr: _userAddr
        });

        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        _message = _buildCCIPMessage(messageBuild);
    }

    /**
     * @notice Calculates CCIP fees and approves LINK for fee payment.
     * @param _message Encoded CCIP message for fee quotation.
     * @return ccipFees_ Fee amount quoted by the router in LINK.
     * @custom:invariant Reverts if LINK balance is insufficient for quoted fee.
     * @custom:invariant On success, router LINK allowance is set to exactly `ccipFees_`.
     */
    function _feeChecks(Client.EVM2AnyMessage memory _message) internal returns (uint256 ccipFees_) {
        // Fee required to send the message
        ccipFees_ = router.getFee(destinationChainSelector, _message);

        uint256 _linkBalance = linkToken.balanceOf(address(this));

        require(_linkBalance >= ccipFees_, SFAndIFCcipSender__NotEnoughBalance(_linkBalance, ccipFees_));

        // Approve the Router to transfer LINK tokens from this contract if needed
        linkToken.forceApprove(address(router), ccipFees_);
    }

    /**
     * @notice Transfers underlying token in, sends message through CCIP router, and clears allowances.
     * @param _userAddr User address from which underlying token is pulled.
     * @param _amountToTransfer underlying token amount to transfer cross-chain.
     * @param _ccipFees Quoted CCIP fee amount (for event accounting).
     * @param _message Encoded CCIP message.
     * @return messageId_ CCIP message identifier returned by router.
     * @custom:invariant On success, router LINK and underlying token allowances are both reset to zero.
     */
    function _sendMessage(
        address _userAddr,
        uint256 _amountToTransfer,
        uint256 _ccipFees,
        Client.EVM2AnyMessage memory _message
    ) internal returns (bytes32 messageId_) {
        underlying.safeTransferFrom(_userAddr, address(this), _amountToTransfer);
        underlying.forceApprove(address(router), _amountToTransfer);

        // Send the message through the router and store the returned message ID
        messageId_ = router.ccipSend(destinationChainSelector, _message);

        // Keep allowances short-lived and deterministic across ERC20 implementations
        linkToken.forceApprove(address(router), 0);
        underlying.forceApprove(address(router), 0);

        // Emit an event with message details
        emit OnTokensTransferred(messageId_, _amountToTransfer, _ccipFees, _userAddr);
    }

    /**
     * @notice Encodes the final CCIP payload and token transfer configuration.
     * @param _messageBuild Pre-assembled message inputs.
     * @return message_ Final CCIP message structure.
     * @custom:invariant `message_.tokenAmounts.length == 1` and token is underlying token.
     * @custom:invariant `message_.data` is encoded as `abi.encode(protocolToCall, protocolCallData)`.
     */
    function _buildCCIPMessage(MessageBuild memory _messageBuild)
        internal
        view
        returns (Client.EVM2AnyMessage memory message_)
    {
        // Set the token amounts
        Client.EVMTokenAmount[] memory _tokenAmounts = new Client.EVMTokenAmount[](1);
        _tokenAmounts[0] = Client.EVMTokenAmount({token: address(underlying), amount: _messageBuild.amount});

        // Function to call in the receiver contract is the standard deposit function from ERC4626
        // deposit(uint256 assets, address receiver)
        bytes memory _protocolCallData =
            abi.encodeWithSignature("deposit(uint256,address)", _messageBuild.amount, _messageBuild.userAddr);

        // Data format: abi.encode(protocolToCall, protocolCallData)
        bytes memory dataToSend = abi.encode(_messageBuild.protocolToCall, _protocolCallData);

        // EVM2AnyMessage struct
        message_ = Client.EVM2AnyMessage({
            receiver: abi.encode(receiverContract),
            data: dataToSend,
            tokenAmounts: _tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({gasLimit: _messageBuild.gasLimit, allowOutOfOrderExecution: true})
            ),
            feeToken: address(linkToken)
        });
    }

    /**
     * @dev Required by the OZ UUPS module.
     * @param newImplementation Address of the candidate implementation.
     * @custom:invariant Only owner can authorize an upgrade.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

