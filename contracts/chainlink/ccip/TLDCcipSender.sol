//SPDX-License-Identifier: GNU GPLv3

/**
 * @title TLDCcipSender
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

contract TLDCcipSender is Ownable2Step {
    using SafeERC20 for IERC20;

    IRouterClient public router;
    IERC20 public immutable linkToken;

    uint64 public immutable destinationChainSelector; // Only Arbitrum (One, Sepolia)
    address public immutable receiverContract;
    address public backendProvider;

    mapping(address token => bool supportedTokens) public isSupportedToken;

    /*//////////////////////////////////////////////////////////////
                            EVENTS & ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnNewSupportedToken(address token);
    event OnBackendProviderSet(address backendProvider);
    event OnTokensTransferred(
        bytes32 indexed messageId,
        uint256 indexed tokenAmount,
        address feeToken,
        uint256 fees
    );

    error TLDCcipSender__AlreadySupportedToken();
    error TLDCcipSender__NotSupportedToken();
    error TLDCcipSender__NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error TLDCcipSender__NothingToWithdraw();
    error TLDCcipSender__FailedToWithdrawEth(address owner, address target, uint256 value);
    error TLDCcipSender__AddressZeroNotAllowed();
    error TLDCcipSender__NotAuthorized();

    modifier notZeroAddress(address addressToCheck) {
        require(addressToCheck != address(0), TLDCcipSender__AddressZeroNotAllowed());
        _;
    }

    /**
     * @param _router The address of the router contract.
     * @param _link The address of the link contract.
     * @param _receiverContract The address of the referral contract. This will be the only receiver
     * @param _chainSelector The chain selector of the destination chain. From the list of supported chains.
     * @param _owner admin address
     */
    constructor(
        address _router,
        address _link,
        address _receiverContract,
        uint64 _chainSelector,
        address _owner,
        address _backendProvider
    ) Ownable(_owner) {
        router = IRouterClient(_router);
        linkToken = IERC20(_link);
        receiverContract = _receiverContract;
        destinationChainSelector = _chainSelector;
        backendProvider = _backendProvider;
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
        require(!isSupportedToken[token], TLDCcipSender__AlreadySupportedToken());

        isSupportedToken[token] = true;

        emit OnNewSupportedToken(token);
    }

    /**
     * @notice Set the address of the backend provider.
     * @param _backendProvider The address of the backend provider.
     */
    function setBackendProvider(
        address _backendProvider
    ) external onlyOwner notZeroAddress(_backendProvider) {
        backendProvider = _backendProvider;

        emit OnBackendProviderSet(_backendProvider);
    }

    /*//////////////////////////////////////////////////////////////
                                PAYMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transfer tokens to receiver contract on the destination chain.
     * @dev Revert if this contract dont have sufficient balance to pay for the fees.
     * @param amountToTransfer token amount to transfer to the receiver contract in the destination chain.
     * @param tokenToTransfer The address of the token to be transferred. Must be in the list of supported tokens.
     * @param contribution The amount of the contribution to be paid in the TLD contract.
     * @param tDAOName The name of the DAO to point in the TLD contract.
     * @param parent The address of the parent if the caller has a referral.
     * @param couponAmount The amount of the coupon if the caller has one.
     * @param feesInLink If true, the fees will be paid in LINK tokens. If false, the fees will be paid in native gas.
     * @return messageId The ID of the message that was sent.
     */
    function payContribution(
        uint256 amountToTransfer,
        address tokenToTransfer,
        uint256 contribution,
        string calldata tDAOName,
        address parent,
        uint256 couponAmount,
        bool feesInLink
    ) external returns (bytes32 messageId) {
        require(isSupportedToken[tokenToTransfer], TLDCcipSender__NotSupportedToken());

        if (couponAmount > 0)
            require(msg.sender == backendProvider, TLDCcipSender__NotAuthorized());

        (address feeTokenAddress, Client.EVM2AnyMessage memory message) = _setup({
            _amountToTransfer: amountToTransfer,
            _tokenToTransfer: tokenToTransfer,
            _contributionAmount: contribution,
            _tDAOName: tDAOName,
            _parent: parent,
            _couponAmount: couponAmount,
            _feesInLink: feesInLink
        });

        uint256 ccipFees = _feeChecks(message, feesInLink);

        messageId = _sendMessage({
            _amountToTransfer: amountToTransfer,
            _tokenToTransfer: tokenToTransfer,
            _feeTokenAddress: feeTokenAddress,
            _ccipFees: ccipFees,
            _message: message
        });
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
        if (amount == 0) revert TLDCcipSender__NothingToWithdraw();

        // Attempt to send the funds, capturing the success status and discarding any return data
        (bool sent, ) = beneficiary.call{value: amount}("");

        // Revert if the send failed, with information about the attempted transfer
        if (!sent) revert TLDCcipSender__FailedToWithdrawEth(msg.sender, beneficiary, amount);
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
        if (amount == 0) revert TLDCcipSender__NothingToWithdraw();

        linkToken.safeTransfer(beneficiary, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _setup(
        uint256 _amountToTransfer,
        address _tokenToTransfer,
        uint256 _contributionAmount,
        string calldata _tDAOName,
        address _parent,
        uint256 _couponAmount,
        bool _feesInLink
    ) internal view returns (address _feeTokenAddressToUse, Client.EVM2AnyMessage memory _message) {
        if (_feesInLink) _feeTokenAddressToUse = address(linkToken);
        else _feeTokenAddressToUse = address(0); // address(0) means fees are paid in native gas

        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        _message = _buildCCIPMessage({
            _token: _tokenToTransfer,
            _amount: _amountToTransfer,
            _feeTokenAddress: _feeTokenAddressToUse,
            _contribution: _contributionAmount,
            _tDAOName: _tDAOName,
            _parent: _parent,
            _newMember: msg.sender,
            _couponAmount: _couponAmount
        });
    }

    function _feeChecks(
        Client.EVM2AnyMessage memory _message,
        bool _feesInLink
    ) internal returns (uint256 _ccipFees) {
        // Fee required to send the message
        _ccipFees = router.getFee(destinationChainSelector, _message);

        uint256 _feeTokenBalance;

        if (_feesInLink) _feeTokenBalance = linkToken.balanceOf(address(this));
        else _feeTokenBalance = address(this).balance;

        if (_ccipFees > _feeTokenBalance)
            revert TLDCcipSender__NotEnoughBalance(_feeTokenBalance, _ccipFees);

        // Approve the Router to transfer LINK tokens from this contract if needed
        if (_feesInLink) linkToken.approve(address(router), _ccipFees);
    }

    function _sendMessage(
        uint256 _amountToTransfer,
        address _tokenToTransfer,
        address _feeTokenAddress,
        uint256 _ccipFees,
        Client.EVM2AnyMessage memory _message
    ) internal returns (bytes32 _messageId) {
        IERC20(_tokenToTransfer).safeTransferFrom(msg.sender, address(this), _amountToTransfer);
        IERC20(_tokenToTransfer).approve(address(router), _amountToTransfer);

        // Send the message through the router and store the returned message ID
        _messageId = router.ccipSend(destinationChainSelector, _message);

        // Emit an event with message details
        emit OnTokensTransferred(_messageId, _amountToTransfer, _feeTokenAddress, _ccipFees);
    }

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
        uint256 _couponAmount
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
                Client.EVMExtraArgsV2({gasLimit: 1_000_000, allowOutOfOrderExecution: true})
            ),
            feeToken: _feeTokenAddress // If address(0) is native token
        });

        return message;
    }
}
