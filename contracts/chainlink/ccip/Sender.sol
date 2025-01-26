//SPDX-License-Identifier: GNU GPLv3

/**
 * @title Sender
 * @author Maikel Ordaz
 * @notice This contract will:
 *          - Interact with the CCIP pprotocol
 *          - Encode the data to send
 *          - Send data to the Receiver contract
 *          - Deployed in Avax (Mainnet and Fuji), Base (Mainnet and Sepolia), Ethereum (Mainnet and Sepolia),
 *            Optimism (Mainnet and Sepolia), Polygon (Mainnet and Amoy)
 */

pragma solidity 0.8.28;

import {IRouterClient} from "ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract Sender is Ownable2Step {
    using SafeERC20 for IERC20;

    IRouterClient public router;
    IERC20 public immutable linkToken;
    IERC20 public immutable usdc;

    uint64 public immutable destinationChainSelector;

    address public immutable receiverContract;

    /*//////////////////////////////////////////////////////////////
                            EVENTS & ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnTokensTransferred(
        bytes32 indexed messageId,
        uint256 indexed tokenAmount,
        address feeToken,
        uint256 fees
    );

    error Sender__NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error Sender__NothingToWithdraw();
    error Sender__FailedToWithdrawEth(address owner, address target, uint256 value);

    /**
     * @param _router The address of the router contract.
     * @param _link The address of the link contract.
     * @param _usdc The address of the USDC contract. // ? Question: Hardcord as only USDC, but we can add more tokens and have them as inputs in the functions
     * @param _receiverContract The address of the referral contract. This will be the only receiver
     * @param _chainSelector The chain selector of the destination chain. From the list of supported chains.
     */
    constructor(
        address _router,
        address _link,
        address _usdc,
        address _receiverContract,
        uint64 _chainSelector
    ) Ownable(msg.sender) {
        router = IRouterClient(_router);
        linkToken = IERC20(_link);
        usdc = IERC20(_usdc);
        receiverContract = _receiverContract;
        destinationChainSelector = _chainSelector;
    }

    receive() external payable {}

    /**
     * @notice Transfer tokens to referrral contract on the destination chain.
     * @notice pay in LINK.
     * @notice the token must be in the list of supported tokens.
     * @dev Revert if this contract dont have sufficient LINK tokens to pay for the fees.
     * @param amount token amount.
     * @return messageId The ID of the message that was sent.
     */
    // ? Question: Here is where we can add more tokens
    function transferUSDCPayLINK(uint256 amount) external returns (bytes32 messageId) {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory message = _buildCCIPMessage(
            receiverContract,
            address(usdc),
            amount,
            address(linkToken) // fees are paid in LINK
        );

        // Fee required to send the message
        uint256 ccipFees = router.getFee(destinationChainSelector, message);

        if (ccipFees > linkToken.balanceOf(address(this)))
            revert Sender__NotEnoughBalance(linkToken.balanceOf(address(this)), ccipFees);

        // Approve the Router to transfer LINK tokens from this contract. It will spend the fees in LINK
        linkToken.approve(address(router), ccipFees);

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        usdc.approve(address(router), amount);

        // Send the message through the router and store the returned message ID
        messageId = router.ccipSend(destinationChainSelector, message);

        // Emit an event with message details
        emit OnTokensTransferred(messageId, amount, address(linkToken), ccipFees);

        // Return the message ID
        return messageId;
    }

    /**
     * @notice Transfer tokens to receiver on the destination chain.
     * @notice Pay in native gas such as ETH on Ethereum or POL on Polygon.
     * @notice the token must be in the list of supported tokens.
     * @notice This function can only be called by the owner.
     * @dev Assumes your contract has sufficient native gas like ETH on Ethereum or POL on Polygon.
     * @param amount token amount.
     * @return messageId The ID of the message that was sent.
     */
    // ? Question: Here is where we can add more tokens
    // ? Question: For this function, the fees are paid in native gas, so the contract needs balance. If not going to be used, we can remove it.
    function transferUSDCPayNative(uint256 amount) external returns (bytes32 messageId) {
        // address(0) means fees are paid in native gas
        Client.EVM2AnyMessage memory message = _buildCCIPMessage(
            receiverContract,
            address(usdc),
            amount,
            address(0)
        );

        // Get the fee required to send the message
        uint256 ccipFees = router.getFee(destinationChainSelector, message);

        if (ccipFees > address(this).balance)
            revert Sender__NotEnoughBalance(address(this).balance, ccipFees);

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        usdc.approve(address(router), amount);

        // Send the message through the router and store the returned message ID
        messageId = router.ccipSend{value: ccipFees}(destinationChainSelector, message);

        // Emit an event with message details
        emit OnTokensTransferred(messageId, amount, address(0), ccipFees);

        // Return the message ID
        return messageId;
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency function to withdraw the entire balance of Ether from the contract.
     * @param beneficiary The address to which the Ether should be transferred.
     * @dev This function reverts if there are no funds to withdraw or if the transfer fails.
     * @dev It should only be callable by the owner of the contract.
     */
    function withdraw(address beneficiary) external onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = address(this).balance;

        // Revert if there is nothing to withdraw
        if (amount == 0) revert Sender__NothingToWithdraw();

        // Attempt to send the funds, capturing the success status and discarding any return data
        (bool sent, ) = beneficiary.call{value: amount}("");

        // Revert if the send failed, with information about the attempted transfer
        if (!sent) revert Sender__FailedToWithdrawEth(msg.sender, beneficiary, amount);
    }

    /**
     * @notice Emergency function to withdraw all tokens of Link.
     * @dev This function reverts with a 'Sender__NothingToWithdraw' error if there are no tokens to withdraw.
     * @param beneficiary The address to which the tokens will be sent.
     */
    function withdrawToken(address beneficiary) external onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = linkToken.balanceOf(address(this));

        // Revert if there is nothing to withdraw
        if (amount == 0) revert Sender__NothingToWithdraw();

        linkToken.safeTransfer(beneficiary, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Construct a CCIP message.
     * @dev This function will create an EVM2AnyMessage struct with the information to tramsfer the tokens and send data.
     * @param _receiver The address of the receiver.
     * @param _token The token to be transferred.
     * @param _amount The amount of the token to be transferred.
     * @param _feeTokenAddress The address of the token used for fees. Set address(0) for native gas.
     * @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
     */
    function _buildCCIPMessage(
        address _receiver,
        address _token,
        uint256 _amount,
        address _feeTokenAddress
    ) internal view returns (Client.EVM2AnyMessage memory) {
        // Set the token amounts
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({
            token: _token,
            amount: _amount
        });
        tokenAmounts[0] = tokenAmount;

        // Todo: Here is calling this test function, but we need to change it to the real one. To do in other PR
        bytes memory dataToSend = abi.encodeWithSignature(
            "checkCaller(address,uint256)",
            msg.sender,
            _amount
        );

        // EVM2AnyMessage struct
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            data: dataToSend,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({
                    gasLimit: 1_000_000, // TODO: Now hardcoded, because is easier, fix this
                    allowOutOfOrderExecution: true
                })
            ),
            feeToken: _feeTokenAddress // If address(0) is native token
        });

        return message;
    }
}
