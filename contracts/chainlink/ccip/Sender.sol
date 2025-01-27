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

    uint64 public immutable destinationChainSelector; // Only Arbitrum (One, Sepolia)
    address public immutable receiverContract;

    mapping(address token => bool supportedTokens) public isSupportedToken;

    /*//////////////////////////////////////////////////////////////
                            EVENTS & ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnNewSupportedToken(address token);
    event OnTokensTransferred(
        bytes32 indexed messageId,
        uint256 indexed tokenAmount,
        address feeToken,
        uint256 fees
    );

    error Sender__AlreadySupportedToken();
    error Sender__NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error Sender__NothingToWithdraw();
    error Sender__FailedToWithdrawEth(address owner, address target, uint256 value);
    error Sender__AddressZeroNotAllowed();

    modifier notZeroAddress(address addressToCheck) {
        require(addressToCheck != address(0), Sender__AddressZeroNotAllowed());
        _;
    }

    /**
     * @param _router The address of the router contract.
     * @param _link The address of the link contract.
     * @param _receiverContract The address of the referral contract. This will be the only receiver
     * @param _chainSelector The chain selector of the destination chain. From the list of supported chains.
     */
    constructor(
        address _router,
        address _link,
        address _receiverContract,
        uint64 _chainSelector
    ) Ownable(msg.sender) {
        router = IRouterClient(_router);
        linkToken = IERC20(_link);
        receiverContract = _receiverContract;
        destinationChainSelector = _chainSelector;
    }

    fallback() external payable {}

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                                SETTINGS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Add a token to the list of supported tokens.
     * @param token The address of the token to be added.
     */
    function addSupportedToken(address token) external onlyOwner notZeroAddress(token) {
        require(!isSupportedToken[token], Sender__AlreadySupportedToken());

        isSupportedToken[token] = true;

        emit OnNewSupportedToken(token);
    }

    /**
     * @notice Transfer tokens to receiver contract on the destination chain.
     * @notice Pay CCIP fees in LINK.
     * @dev Revert if this contract dont have sufficient LINK tokens to pay for the fees.
     * @param amountToTransfer token amount to transfer to the receiver contract in the destination chain.
     * @param tokenToTransfer The address of the token to be transferred. Must be in the list of supported tokens.
     * @param contribution The amount of the contribution to be paid in the TLD contract.
     * @param tDAOName The name of the DAO to point in the TLD contract.
     * @param parent The address of the parent if the caller has a referral.
     * @param couponAmount The amount of the coupon if the caller has one.
     * @param gasLimit The gas limit for the transaction. If 0, a default value of 1_000_000 will be used.
     * @return messageId The ID of the message that was sent.
     */
    function transferUSDCPayLINK(
        uint256 amountToTransfer,
        address tokenToTransfer,
        uint256 contribution,
        string calldata tDAOName,
        address parent,
        uint256 couponAmount,
        uint256 gasLimit
    ) external returns (bytes32 messageId) {
        // If no gas limit is provided, set a default value of 1_000_000
        if (gasLimit == 0) gasLimit = 1_000_000;

        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory message = _buildCCIPMessage({
            _token: tokenToTransfer,
            _amount: amountToTransfer,
            _feeTokenAddress: address(linkToken), // fees are paid in LINK
            _contribution: contribution,
            _tDAOName: tDAOName,
            _parent: parent,
            _newMember: msg.sender,
            _couponAmount: couponAmount,
            _gasLimit: gasLimit
        });

        // Fee required to send the message
        uint256 ccipFees = router.getFee(destinationChainSelector, message);

        if (ccipFees > linkToken.balanceOf(address(this)))
            revert Sender__NotEnoughBalance(linkToken.balanceOf(address(this)), ccipFees);

        // Approve the Router to transfer LINK tokens from this contract. It will spend the fees in LINK
        linkToken.approve(address(router), ccipFees);

        IERC20(tokenToTransfer).safeTransferFrom(msg.sender, address(this), amountToTransfer);
        IERC20(tokenToTransfer).approve(address(router), amountToTransfer);

        // Send the message through the router and store the returned message ID
        messageId = router.ccipSend(destinationChainSelector, message);

        // Emit an event with message details
        emit OnTokensTransferred(messageId, amountToTransfer, address(linkToken), ccipFees);
    }

    /**
     * @notice Transfer tokens to receiver on the destination chain.
     * @notice Pay in native gas such as ETH on Ethereum or POL on Polygon.
     * @notice the token must be in the list of supported tokens.
     * @dev Assumes your contract has sufficient native gas.
     * @param amountToTransfer token amount.
     * @param tokenToTransfer The address of the token to be transferred. Must be in the list of supported tokens.
     * @param contribution The amount of the contribution to be paid in the TLD contract.
     * @param tDAOName The name of the DAO to point in the TLD contract.
     * @param parent The address of the parent if the caller has a referral.
     * @param couponAmount The amount of the coupon if the caller has one.
     * @param gasLimit The gas limit for the transaction. If 0, a default value of 1_000_000 will be used.
     * @return messageId The ID of the message that was sent.
     */
    // ? Question: For this function, the fees are paid in native gas, so the contract needs balance. If not going to be used, we can remove it.
    function transferUSDCPayNative(
        uint256 amountToTransfer,
        address tokenToTransfer,
        uint256 contribution,
        string calldata tDAOName,
        address parent,
        uint256 couponAmount,
        uint256 gasLimit
    ) external returns (bytes32 messageId) {
        // If no gas limit is provided, set a default value of 1_000_000
        if (gasLimit == 0) gasLimit = 1_000_000;

        // address(0) means fees are paid in native gas
        Client.EVM2AnyMessage memory message = _buildCCIPMessage({
            _token: tokenToTransfer,
            _amount: amountToTransfer,
            _feeTokenAddress: address(0),
            _contribution: contribution,
            _tDAOName: tDAOName,
            _parent: parent,
            _newMember: msg.sender,
            _couponAmount: couponAmount,
            _gasLimit: gasLimit
        });

        // Get the fee required to send the message
        uint256 ccipFees = router.getFee(destinationChainSelector, message);

        if (ccipFees > address(this).balance)
            revert Sender__NotEnoughBalance(address(this).balance, ccipFees);

        IERC20(tokenToTransfer).safeTransferFrom(msg.sender, address(this), amountToTransfer);
        IERC20(tokenToTransfer).approve(address(router), amountToTransfer);

        // Send the message through the router and store the returned message ID
        messageId = router.ccipSend{value: ccipFees}(destinationChainSelector, message);

        // Emit an event with message details
        emit OnTokensTransferred(messageId, amountToTransfer, address(0), ccipFees);
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency function to withdraw the entire balance of Ether from the contract.
     * @param beneficiary The address to which the Ether should be transferred.
     * @dev This function reverts with a 'Sender__NothingToWithdraw' error, if there are no funds to withdraw
     * @dev It should only be callable by the owner of the contract.
     * @dev This ether is used to pay the fees of the CCIP protocol, when using native gas.
     */
    function withdraw(address beneficiary) external onlyOwner notZeroAddress(beneficiary) {
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
     * @notice Emergency function to withdraw all Link tokens.
     * @dev This function reverts with a 'Sender__NothingToWithdraw' error if there are no tokens to withdraw.
     * @param beneficiary The address to which the tokens will be sent.
     */
    function withdrawToken(address beneficiary) external onlyOwner notZeroAddress(beneficiary) {
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
     * @param _token The token to be transferred.
     * @param _amount The amount of the token to be transferred.
     * @param _feeTokenAddress The address of the token used for fees. Set address(0) for native gas.
     * @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
     */
    function _buildCCIPMessage(
        address _token,
        uint256 _amount,
        address _feeTokenAddress,
        uint256 _contribution,
        string calldata _tDAOName,
        address _parent,
        address _newMember,
        uint256 _couponAmount,
        uint256 _gasLimit
    ) internal view returns (Client.EVM2AnyMessage memory) {
        // Set the token amounts
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({
            token: _token,
            amount: _amount
        });
        tokenAmounts[0] = tokenAmount;

        // Function to call in the receiver contract
        // payContributionOnBehalfOf(uint256 contribution, string calldata tDAOName, address parent, address newMember, uint256 couponAmount)
        bytes memory dataToSend = abi.encodeWithSignature(
            "payContributionOnBehalfOf(uint256,string,address,address,uint256)",
            _contribution,
            _tDAOName,
            _parent,
            _newMember,
            _couponAmount
        );

        // EVM2AnyMessage struct
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiverContract),
            data: dataToSend,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({gasLimit: _gasLimit, allowOutOfOrderExecution: true})
            ),
            feeToken: _feeTokenAddress // If address(0) is native token
        });

        return message;
    }
}
