//SPDX-License-Identifier: GNU GPLv3

/**
 * @title SaveInvestCCIPSender
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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {Client} from "ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {AggregatorV3Interface} from "ccip/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniversalRouter} from "contracts/interfaces/helpers/IUniversalRouter.sol";
import {IPermit2AllowanceTransfer} from "contracts/interfaces/helpers/IPermit2AllowanceTransfer.sol";

contract SaveInvestCCIPSender is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    IRouterClient private router;
    IERC20 private linkToken;
    IERC20 private underlying;

    uint64 public destinationChainSelector; // Only Arbitrum (One, Sepolia)
    address public receiverContract;

    // APPEND-ONLY STORAGE (upgrade-safe for deployed proxy)
    IUniversalRouter private universalRouter;
    IPermit2AllowanceTransfer private permit2;
    AggregatorV3Interface private linkUsdPriceFeed;
    AggregatorV3Interface private usdcUsdPriceFeed;
    bool public isUserPayingCCIPFee;

    uint256 public constant MIN_DEPOSIT = 100e6; // 100 USDC (6 decimals)
    uint256 public constant MAX_GAS_LIMIT = 600_000; // Receiver decode/validation + Vault.deposit path + margin
    uint256 public constant LINK_TOKEN_DECIMALS_FACTOR = 1e18; // LINK uses 18 decimals
    uint256 public constant USDC_TOKEN_DECIMALS_FACTOR = 1e6; // USDC uses 6 decimals

    struct MessageBuild {
        string protocolName;
        uint256 amount;
        uint256 gasLimit;
        address userAddr;
    }

    /*//////////////////////////////////////////////////////////////
                            EVENTS & ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnReceiverContractSet(address oldReceiverContract, address newReceiverContract);
    event OnUserPaysCCIPFeeToggled(bool enabled);
    event OnFeePaymentInfraSet(
        address universalRouter, address permit2, address linkUsdPriceFeed, address usdcUsdPriceFeed
    );
    event OnCCIPFeeCollectedInUnderlying(address indexed user, uint256 linkFeeAmount, uint256 usdcFeeAmount);
    event OnCollectedUsdcSwappedToLink(uint256 usdcAmountIn, uint256 linkAmountOut);
    event OnTokensTransferred(
        bytes32 indexed messageId, uint256 indexed tokenAmount, uint256 indexed fees, address userAddr
    );

    error SaveInvestCCIPSender__AddressZeroNotAllowed();
    error SaveInvestCCIPSender__ZeroTransferNotAllowed();
    error SaveInvestCCIPSender__AmountBelowMinimum(uint256 amount, uint256 minimum);
    error SaveInvestCCIPSender__GasLimitTooHigh(uint256 gasLimit, uint256 maxGasLimit);
    error SaveInvestCCIPSender__NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error SaveInvestCCIPSender__NothingToWithdraw();
    error SaveInvestCCIPSender__FeePaymentInfraNotConfigured();
    error SaveInvestCCIPSender__InvalidPriceFeedAnswer(address feed, int256 answer);
    error SaveInvestCCIPSender__PriceFeedRoundIncomplete(address feed);
    error SaveInvestCCIPSender__NothingToSwap();
    error SaveInvestCCIPSender__CollectedUsdcNotFullySwapped(uint256 remainingUsdc);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier notZeroAddress(address addressToCheck) {
        require(addressToCheck != address(0), SaveInvestCCIPSender__AddressZeroNotAllowed());
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
     * @param _receiverContract Deployed CCIP receiver contract in the destination chain.
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
            SaveInvestCCIPSender__AddressZeroNotAllowed()
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
     * @dev Destination must be the CCIP receiver; that receiver routes to vaults by protocol name.
     * @param _receiverContract New receiver contract address.
     * @custom:invariant On success, `receiverContract` is non-zero and equals `_receiverContract`.
     */
    function setReceiverContract(address _receiverContract) external onlyOwner notZeroAddress(_receiverContract) {
        address oldReceiverContract = receiverContract;
        receiverContract = _receiverContract;

        emit OnReceiverContractSet(oldReceiverContract, receiverContract);
    }

    /**
     * @notice Toggles whether users reimburse CCIP fees in underlying token (USDC).
     * @dev When enabled, sender still spends LINK for CCIP execution, but collects an equivalent USDC quote from the caller.
     */
    function toggleUserPaysCCIPFee() external onlyOwner {
        isUserPayingCCIPFee = !isUserPayingCCIPFee;
        emit OnUserPaysCCIPFeeToggled(isUserPayingCCIPFee);
    }

    /**
     * @notice Sets the infrastructure used for user fee reimbursement quoting and owner fee swaps.
     * @dev Feed prices are only used to quote LINK fees into USDC; the actual owner swap is performed via Universal Router.
     */
    function setFeePaymentInfrastructure(
        address _universalRouter,
        address _permit2,
        address _linkUsdPriceFeed,
        address _usdcUsdPriceFeed
    ) external onlyOwner {
        require(
            _universalRouter != address(0) && _permit2 != address(0) && _linkUsdPriceFeed != address(0)
                && _usdcUsdPriceFeed != address(0),
            SaveInvestCCIPSender__AddressZeroNotAllowed()
        );

        universalRouter = IUniversalRouter(_universalRouter);
        permit2 = IPermit2AllowanceTransfer(_permit2);
        linkUsdPriceFeed = AggregatorV3Interface(_linkUsdPriceFeed);
        usdcUsdPriceFeed = AggregatorV3Interface(_usdcUsdPriceFeed);

        emit OnFeePaymentInfraSet(_universalRouter, _permit2, _linkUsdPriceFeed, _usdcUsdPriceFeed);
    }

    /*//////////////////////////////////////////////////////////////
                                PAYMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transfer tokens to receiver contract on the destination chain.
     * @dev Revert if this contract dont have sufficient LINK balance to pay for the fees.
     * @dev Enforces a minimum deposit of 100 USDC (6 decimals) to reduce LINK-fee griefing from tiny sends.
     * @dev Caps user-provided gasLimit to reduce LINK-fee griefing via oversized destination execution limits.
     * @param protocolName The protocol name to resolve in destination chain AddressManager.
     * @param amountToTransfer token amount to transfer to the receiver contract in the destination chain.
     * @param gasLimit gas allowed by the user for destination execution, capped by `MAX_GAS_LIMIT`.
     * @return messageId The ID of the message that was sent.
     * @custom:invariant On success, message always encodes protocol name + `deposit(uint256,address)` call data.
     * @custom:invariant On success, both LINK and underlying router allowances are reset to zero at the end of execution.
     */
    function sendMessage(string calldata protocolName, uint256 amountToTransfer, uint256 gasLimit)
        external
        returns (bytes32 messageId)
    {
        _validateSendMessageInputs(amountToTransfer, gasLimit);
        address userAddr = msg.sender;

        Client.EVM2AnyMessage memory message = _setup({
            _protocolName: protocolName, _amountToTransfer: amountToTransfer, _gasLimit: gasLimit, _userAddr: userAddr
        });

        uint256 CCIPFees = router.getFee(destinationChainSelector, message);

        if (isUserPayingCCIPFee) {
            uint256 usdcFeeAmount = _quoteUsdcForLinkAmount(CCIPFees);
            underlying.safeTransferFrom(userAddr, address(this), usdcFeeAmount);
            emit OnCCIPFeeCollectedInUnderlying(userAddr, CCIPFees, usdcFeeAmount);
        }

        _approveLinkFees(CCIPFees);

        messageId = _sendMessage({
            _userAddr: userAddr, _amountToTransfer: amountToTransfer, _CCIPFees: CCIPFees, _message: message
        });
    }

    /**
     * @notice Previews the CCIP fee for a hipothetical `sendMessage` call.
     * @dev Returns both the LINK fee quoted by the CCIP router and the USDC equivalent based on Chainlink USD feeds.
     * @param protocolName The protocol name to resolve in destination chain AddressManager.
     * @param amountToTransfer token amount to transfer to the receiver contract in the destination chain.
     * @param gasLimit gas allowed by the caller for destination execution, capped by `MAX_GAS_LIMIT`.
     * @return linkAmount LINK fee quoted by the CCIP router.
     * @return usdcAmount USDC amount required to reimburse `linkAmount` at current feed prices.
     */
    function previewCCIPFee(string calldata protocolName, uint256 amountToTransfer, uint256 gasLimit)
        external
        view
        returns (uint256 linkAmount, uint256 usdcAmount)
    {
        _validateSendMessageInputs(amountToTransfer, gasLimit);

        Client.EVM2AnyMessage memory message = _setup({
            _protocolName: protocolName,
            _amountToTransfer: amountToTransfer,
            _gasLimit: gasLimit,
            _userAddr: msg.sender // it actually doesn't matter whose address we use here, since this is just an estimation
        });

        return _previewMessageFees(message);
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

        require(amount > 0, SaveInvestCCIPSender__NothingToWithdraw());

        linkToken.safeTransfer(beneficiary, amount);
    }

    /**
     * @notice Swaps the contract's entire collected USDC balance into LINK using Uniswap Universal Router.
     * @dev Owner supplies the pre-encoded router commands/inputs/deadline.
     * @dev This function assumes commands spend the contract's full USDC balance; it reverts if any USDC remains.
     * @param commands Universal Router command bytes (e.g. includes V4 swap).
     * @param inputs Universal Router command inputs.
     * @param deadline Universal Router execution deadline.
     * @return linkAmountOut LINK amount received by this contract from the swap.
     */
    function swapAllCollectedUsdcToLink(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        onlyOwner
        returns (uint256 linkAmountOut)
    {
        _requireSwapInfraConfigured();

        uint256 usdcAmountIn = underlying.balanceOf(address(this));
        require(usdcAmountIn > 0, SaveInvestCCIPSender__NothingToSwap());

        uint256 linkBalanceBefore = linkToken.balanceOf(address(this));

        _ensurePermit2Max(underlying);
        universalRouter.execute(commands, inputs, deadline);

        uint256 remainingUsdc = underlying.balanceOf(address(this));
        require(remainingUsdc == 0, SaveInvestCCIPSender__CollectedUsdcNotFullySwapped(remainingUsdc));

        uint256 linkBalanceAfter = linkToken.balanceOf(address(this));
        linkAmountOut = linkBalanceAfter - linkBalanceBefore;

        emit OnCollectedUsdcSwappedToLink(usdcAmountIn, linkAmountOut);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Builds the complete CCIP message from user-level parameters.
     * @param _protocolName Protocol name indicating target vault in destination AddressManager.
     * @param _amountToTransfer Amount of underlying token to transfer cross-chain.
     * @param _gasLimit Gas limit requested for destination execution.
     * @param _userAddr Receiver/user address for vault deposit.
     * @return _message Encoded EVM2AnyMessage ready for fee estimation/sending.
     * @custom:invariant Returned message contains exactly one token transfer amount (underlying).
     */
    function _setup(string memory _protocolName, uint256 _amountToTransfer, uint256 _gasLimit, address _userAddr)
        internal
        view
        returns (Client.EVM2AnyMessage memory _message)
    {
        MessageBuild memory messageBuild = MessageBuild({
            protocolName: _protocolName, amount: _amountToTransfer, gasLimit: _gasLimit, userAddr: _userAddr
        });

        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        _message = _buildCCIPMessage(messageBuild);
    }

    /**
     * @notice Ensures the sender has enough LINK and approves the router to spend the quoted fee.
     * @param _CCIPFees Fee amount quoted by the router in LINK.
     * @custom:invariant Reverts if LINK balance is insufficient for quoted fee.
     * @custom:invariant On success, router LINK allowance is set to exactly `_CCIPFees`.
     */
    function _approveLinkFees(uint256 _CCIPFees) internal {
        uint256 _linkBalance = linkToken.balanceOf(address(this));

        require(_linkBalance >= _CCIPFees, SaveInvestCCIPSender__NotEnoughBalance(_linkBalance, _CCIPFees));

        // Approve the Router to transfer LINK tokens from this contract if needed
        linkToken.forceApprove(address(router), _CCIPFees);
    }

    /**
     * @notice Quotes the CCIP LINK fee and its USDC equivalent using Chainlink USD feeds.
     * @dev USDC quote is only reimbursement/accounting guidance; actual conversion to LINK happens later via owner swap.
     * @param _message Encoded CCIP message for fee quotation.
     * @return linkAmount_ LINK fee quoted by the CCIP router.
     * @return usdcAmount_ USDC amount calculated to cover `linkAmount_`.
     */
    function _previewMessageFees(Client.EVM2AnyMessage memory _message)
        internal
        view
        returns (uint256 linkAmount_, uint256 usdcAmount_)
    {
        linkAmount_ = router.getFee(destinationChainSelector, _message);
        usdcAmount_ = _quoteUsdcForLinkAmount(linkAmount_);
    }

    /**
     * @notice Transfers underlying token in, sends message through CCIP router, and clears allowances.
     * @param _userAddr User address from which underlying token is pulled.
     * @param _amountToTransfer underlying token amount to transfer cross-chain.
     * @param _CCIPFees Quoted CCIP fee amount (for event accounting).
     * @param _message Encoded CCIP message.
     * @return messageId_ CCIP message identifier returned by router.
     * @custom:invariant On success, router LINK and underlying token allowances are both reset to zero.
     */
    function _sendMessage(
        address _userAddr,
        uint256 _amountToTransfer,
        uint256 _CCIPFees,
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
        emit OnTokensTransferred(messageId_, _amountToTransfer, _CCIPFees, _userAddr);
    }

    /**
     * @notice Encodes the final CCIP payload and token transfer configuration.
     * @param _messageBuild Pre-assembled message inputs.
     * @return message_ Final CCIP message structure.
     * @custom:invariant `message_.tokenAmounts.length == 1` and token is underlying token.
     * @custom:invariant `message_.data` is encoded as `abi.encode(protocolName, protocolCallData)`.
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

        // Data format: abi.encode(protocolName, protocolCallData)
        bytes memory dataToSend = abi.encode(_messageBuild.protocolName, _protocolCallData);

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

    function _validateSendMessageInputs(uint256 amountToTransfer, uint256 gasLimit) internal pure {
        require(amountToTransfer > 0, SaveInvestCCIPSender__ZeroTransferNotAllowed());
        require(
            amountToTransfer >= MIN_DEPOSIT, SaveInvestCCIPSender__AmountBelowMinimum(amountToTransfer, MIN_DEPOSIT)
        );
        require(gasLimit <= MAX_GAS_LIMIT, SaveInvestCCIPSender__GasLimitTooHigh(gasLimit, MAX_GAS_LIMIT));
    }

    function _quoteUsdcForLinkAmount(uint256 _linkAmount) internal view returns (uint256 usdcAmount_) {
        _requireFeeQuoteFeedsConfigured();

        (uint256 linkUsdPrice, uint8 linkUsdFeedDecimals) = _readValidatedPrice(linkUsdPriceFeed);
        (uint256 usdcUsdPrice, uint8 usdcUsdFeedDecimals) = _readValidatedPrice(usdcUsdPriceFeed);

        // Convert LINK fee (18 decimals) into USDC amount (6 decimals) using USD price feeds:
        // usdc = ceil(linkAmount * linkUsdPrice * 10^(USDC + usdcFeedDec) / (1e18 * usdcUsdPrice * 10^(linkFeedDec)))
        uint256 numeratorMultiplier = USDC_TOKEN_DECIMALS_FACTOR * (10 ** uint256(usdcUsdFeedDecimals));
        uint256 denominator = LINK_TOKEN_DECIMALS_FACTOR * usdcUsdPrice * (10 ** uint256(linkUsdFeedDecimals));

        usdcAmount_ = Math.mulDiv(_linkAmount, linkUsdPrice * numeratorMultiplier, denominator, Math.Rounding.Ceil);
    }

    function _readValidatedPrice(AggregatorV3Interface _feed) internal view returns (uint256 price_, uint8 decimals_) {
        decimals_ = _feed.decimals();
        (, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = _feed.latestRoundData();

        require(answer > 0, SaveInvestCCIPSender__InvalidPriceFeedAnswer(address(_feed), answer));
        require(updatedAt != 0 && answeredInRound != 0, SaveInvestCCIPSender__PriceFeedRoundIncomplete(address(_feed)));

        price_ = uint256(answer);
    }

    function _requireFeeQuoteFeedsConfigured() internal view {
        require(
            address(linkUsdPriceFeed) != address(0) && address(usdcUsdPriceFeed) != address(0),
            SaveInvestCCIPSender__FeePaymentInfraNotConfigured()
        );
    }

    function _requireSwapInfraConfigured() internal view {
        require(
            address(universalRouter) != address(0) && address(permit2) != address(0),
            SaveInvestCCIPSender__FeePaymentInfraNotConfigured()
        );
    }

    function _ensurePermit2Max(IERC20 _tokenIn) internal {
        // ERC20 allowance -> Permit2
        uint256 _erc20Allowance = _tokenIn.allowance(address(this), address(permit2));
        if (_erc20Allowance != type(uint256).max) {
            _tokenIn.forceApprove(address(permit2), type(uint256).max);
        }

        // Permit2 allowance -> UniversalRouter
        (uint160 _allowed, uint48 _expiration,) =
            permit2.allowance(address(this), address(_tokenIn), address(universalRouter));

        if (_allowed != type(uint160).max || _expiration != type(uint48).max) {
            permit2.approve(address(_tokenIn), address(universalRouter), type(uint160).max, type(uint48).max);
        }
    }

    /**
     * @dev Required by the OZ UUPS module.
     * @param newImplementation Address of the candidate implementation.
     * @custom:invariant Only owner can authorize an upgrade.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

