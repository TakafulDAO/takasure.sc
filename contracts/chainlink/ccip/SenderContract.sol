//SPDX-License-Identifier: GNU GPLv3

/**
 * @title TokenTransferSource
 * @author Maikel Ordaz
 * @notice This contract is used to interact with the CCIP pprotocol to transfer tokens across chains
 */

pragma solidity 0.8.28;

import {IRouterClient} from "ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract TokenTransferSource is Ownable2Step {
    using SafeERC20 for IERC20;

    IRouterClient private router;
    IERC20 private immutable linkToken;
    IERC20 private immutable usdc;

    uint64 private constant ARB_ONE_CHAIN_SELECTOR = 4949039107694359620;

    address private immutable referralContract;

    /*//////////////////////////////////////////////////////////////
                            EVENTS & ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnTokensTransferred(
        bytes32 indexed messageId,
        uint256 indexed tokenAmount,
        address feeToken,
        uint256 fees
    );

    error TokenTransferSource__NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error TokenTransferSource__NothingToWithdraw();
    error TokenTransferSource__FailedToWithdrawEth(address owner, address target, uint256 value);
    error TokenTransferSource__DestinationChainNotAllowlisted(uint64 destinationChainSelector);
    error TokenTransferSource__InvalidReceiverAddress();

    /**
     * @param _router The address of the router contract.
     * @param _link The address of the link contract.
     * @param _referralContract The address of the referral contract. This will be the only receiver
     */
    constructor(
        address _router,
        address _link,
        address _usdc,
        address _referralContract
    ) Ownable(msg.sender) {
        router = IRouterClient(_router);
        linkToken = IERC20(_link);
        usdc = IERC20(_usdc);
        referralContract = _referralContract;
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
    // TODO: We can add an input for another token, here only USDC
    function transferUSDCPayLINK(uint256 amount) external returns (bytes32 messageId) {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory message = _buildCCIPMessage(
            referralContract,
            address(usdc),
            amount,
            address(linkToken) // fees are paid in LINK
        );

        // Fee required to send the message
        uint256 ccipFees = router.getFee(ARB_ONE_CHAIN_SELECTOR, message);

        if (ccipFees > linkToken.balanceOf(address(this)))
            revert TokenTransferSource__NotEnoughBalance(
                linkToken.balanceOf(address(this)),
                ccipFees
            );

        // Approve the Router to transfer LINK tokens from this contract. It will spend the fees in LINK
        linkToken.approve(address(router), ccipFees);

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        usdc.approve(address(router), amount);

        // Send the message through the router and store the returned message ID
        messageId = router.ccipSend(ARB_ONE_CHAIN_SELECTOR, message);

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
    // TODO: We can add an input for another token, here only USDC
    function transferUSDCPayNative(uint256 amount) external returns (bytes32 messageId) {
        // address(0) means fees are paid in native gas
        Client.EVM2AnyMessage memory message = _buildCCIPMessage(
            referralContract,
            address(usdc),
            amount,
            address(0)
        );

        // Get the fee required to send the message
        uint256 ccipFees = router.getFee(ARB_ONE_CHAIN_SELECTOR, message);

        if (ccipFees > address(this).balance)
            revert TokenTransferSource__NotEnoughBalance(address(this).balance, ccipFees);

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        usdc.approve(address(router), amount);

        // Send the message through the router and store the returned message ID
        messageId = router.ccipSend{value: ccipFees}(ARB_ONE_CHAIN_SELECTOR, message);

        // Emit an event with message details
        emit OnTokensTransferred(messageId, amount, address(0), ccipFees);

        // Return the message ID
        return messageId;
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency function. Allows the contract owner to withdraw the entire balance of Ether from the contract.
     * @param beneficiary The address to which the Ether should be transferred.
     * @dev This function reverts if there are no funds to withdraw or if the transfer fails.
     * @dev It should only be callable by the owner of the contract.
     */
    function withdraw(address beneficiary) external onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = address(this).balance;

        // Revert if there is nothing to withdraw
        if (amount == 0) revert TokenTransferSource__NothingToWithdraw();

        // Attempt to send the funds, capturing the success status and discarding any return data
        (bool sent, ) = beneficiary.call{value: amount}("");

        // Revert if the send failed, with information about the attempted transfer
        if (!sent) revert TokenTransferSource__FailedToWithdrawEth(msg.sender, beneficiary, amount);
    }

    /**
     * @notice Emergency function. Allows the owner of the contract to withdraw all tokens of a specific ERC20 token.
     * @dev This function reverts with a 'TokenTransferSource__NothingToWithdraw' error if there are no tokens to withdraw.
     * @param beneficiary The address to which the tokens will be sent.
     */
    function withdrawToken(address beneficiary) external onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = usdc.balanceOf(address(this));

        // Revert if there is nothing to withdraw
        if (amount == 0) revert TokenTransferSource__NothingToWithdraw();

        usdc.safeTransfer(beneficiary, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Construct a CCIP message.
     * @dev This function will create an EVM2AnyMessage struct with all the necessary information for tokens transfer.
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
    ) internal pure returns (Client.EVM2AnyMessage memory) {
        // Set the token amounts
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: _token, amount: _amount});

        // EVM2AnyMessage struct
        return
            Client.EVM2AnyMessage({
                receiver: abi.encode(_receiver),
                data: "", // No data. No message
                tokenAmounts: tokenAmounts,
                extraArgs: Client._argsToBytes(
                    Client.EVMExtraArgsV2({
                        gasLimit: 0, // Gas limit for the callback on the destination chain // TODO: Now hardcoded, because is easier, fix this
                        allowOutOfOrderExecution: true
                    })
                ),
                feeToken: _feeTokenAddress // If address(0) is native token
            });
    }
}
