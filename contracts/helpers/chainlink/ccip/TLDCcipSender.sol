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
 * @dev Upgradeable contract with UUPS pattern
 */

pragma solidity 0.8.28;

import {IRouterClient} from "ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Client} from "ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @custom:oz-upgrades-from contracts/version_previous_contracts/TLDCcipSenderV1.sol:TLDCcipSenderV1
contract TLDCcipSender is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    using SafeERC20 for IERC20;

    IRouterClient public router;
    IERC20 public linkToken;

    uint64 public destinationChainSelector; // Only Arbitrum (One, Sepolia)
    address public receiverContract;
    address public backendProvider;

    uint256 private constant MINIMUM_CONTRIBUTION = 25e6; // 25 USDC
    uint256 private constant MAXIMUM_CONTRIBUTION = 250e6; // 250 USDC

    mapping(address token => bool supportedTokens) public isSupportedToken;

    bool public isPrejoinEnabled;

    struct MessageBuild {
        address token;
        uint256 amount;
        uint256 gasLimit;
        uint256 contribution;
        address parent;
        address newMember;
        uint256 couponAmount;
        uint256 membershipDuration;
    }

    /*//////////////////////////////////////////////////////////////
                            EVENTS & ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnNewSupportedToken(address token);
    event OnBackendProviderSet(address backendProvider);
    event OnTokensTransferred(
        bytes32 indexed messageId,
        uint256 indexed tokenAmount,
        uint256 indexed fees,
        address user,
        bool isPrejoiner
    );
    event OnTokenRemoved(address token);
    event OnPrejoinEnabled(bool isPrejoinEnabled);

    error TLDCcipSender__ZeroTransferNotAllowed();
    error TLDCcipSender__AlreadySupportedToken();
    error TLDCcipSender__NotSupportedToken();
    error TLDCcipSender__NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error TLDCcipSender__NothingToWithdraw();
    error TLDCcipSender__AddressZeroNotAllowed();
    error TLDCcipSender__NotAuthorized();
    error TLDCcipSender__ContributionOutOfRange();
    error TLDCcipSender__WrongTransferAmount();

    modifier notZeroAddress(address addressToCheck) {
        require(addressToCheck != address(0), TLDCcipSender__AddressZeroNotAllowed());
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    /**
     * @param _router The address of the router contract.
     * @param _link The address of the link contract.
     * @param _receiverContract Receiver contract in the destination blockchain. This will be the only receiver
     * @param _chainSelector The chain selector of the destination chain. Only Arbitrum (One, Sepolia) is supported.
     * @param _owner admin address
     * @param _backendProvider The address with privileges to pay contributions with coupon codes
     */
    function initialize(
        address _router,
        address _link,
        address _receiverContract,
        uint64 _chainSelector,
        address _owner,
        address _backendProvider
    )
        external
        initializer
        notZeroAddress(_router)
        notZeroAddress(_link)
        notZeroAddress(_receiverContract)
        notZeroAddress(_owner)
        notZeroAddress(_backendProvider)
    {
        __UUPSUpgradeable_init();
        __Ownable2Step_init();
        __Ownable_init(_owner);

        router = IRouterClient(_router);
        linkToken = IERC20(_link);

        receiverContract = _receiverContract;
        destinationChainSelector = _chainSelector;
        backendProvider = _backendProvider;
    }

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
     * @notice Remove a token from the list of supported tokens.
     * @param token The address of the token to be removed.
     */
    function removeSupportedToken(address token) external onlyOwner notZeroAddress(token) {
        require(isSupportedToken[token], TLDCcipSender__NotSupportedToken());

        isSupportedToken[token] = false;

        emit OnTokenRemoved(token);
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

    /**
     * @notice Set the address of the receiver contract.
     * @dev The first receiver will be the PrejoinModule. When the DAO is launched we change this to the EntryModule.
     * @param _receiverContract New receiver contract address.
     */
    function setReceiverContract(
        address _receiverContract
    ) external onlyOwner notZeroAddress(_receiverContract) {
        receiverContract = _receiverContract;
    }

    function enablePrejoin(bool _isPrejoinEnabled) external onlyOwner {
        isPrejoinEnabled = _isPrejoinEnabled;
        emit OnPrejoinEnabled(_isPrejoinEnabled);
    }

    /*//////////////////////////////////////////////////////////////
                                PAYMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transfer tokens to receiver contract on the destination chain.
     * @dev Revert if this contract dont have sufficient LINK balance to pay for the fees.
     * @param amountToTransfer token amount to transfer to the receiver contract in the destination chain.
     * @param tokenToTransfer The address of the token to be transferred. Must be in the list of supported tokens.
     * @param gasLimit gas allowed by the user to be the maximum spend in the destination blockchain by the CCIP protocol
     * @param contribution The amount of the contribution to be paid in the TLD contract.
     * @param parent The address of the parent if the caller has a referral.
     * @param couponAmount The amount of the coupon if the caller has one.
     * @param membershipDuration The duration of the membership in seconds. Only used if prejoin is disabled.
     * @return messageId The ID of the message that was sent.
     */
    function sendMessage(
        uint256 amountToTransfer,
        address tokenToTransfer,
        uint256 gasLimit,
        uint256 contribution,
        address parent,
        address newMember,
        uint256 couponAmount,
        uint256 membershipDuration
    ) external returns (bytes32 messageId) {
        require(amountToTransfer > 0, TLDCcipSender__ZeroTransferNotAllowed());
        require(isSupportedToken[tokenToTransfer], TLDCcipSender__NotSupportedToken());
        require(
            contribution >= MINIMUM_CONTRIBUTION && contribution <= MAXIMUM_CONTRIBUTION,
            TLDCcipSender__ContributionOutOfRange()
        );
        require(
            amountToTransfer == contribution - couponAmount,
            TLDCcipSender__WrongTransferAmount()
        );

        if (couponAmount > 0)
            require(msg.sender == backendProvider, TLDCcipSender__NotAuthorized());
        else require(msg.sender == newMember, TLDCcipSender__NotAuthorized());

        Client.EVM2AnyMessage memory message = _setup({
            _amountToTransfer: amountToTransfer,
            _tokenToTransfer: tokenToTransfer,
            _gasLimit: gasLimit,
            _contributionAmount: contribution,
            _parent: parent,
            _newMember: newMember,
            _couponAmount: couponAmount,
            _membershipDuration: membershipDuration
        });

        uint256 ccipFees = _feeChecks(message);

        messageId = _sendMessage({
            _newMember: newMember,
            _amountToTransfer: amountToTransfer,
            _tokenToTransfer: tokenToTransfer,
            _ccipFees: ccipFees,
            _message: message
        });
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency function to withdraw all Link tokens.
     * @param beneficiary The address to which the tokens will be sent.
     */
    function withdrawLink(address beneficiary) external onlyOwner notZeroAddress(beneficiary) {
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
        uint256 _gasLimit,
        uint256 _contributionAmount,
        address _parent,
        address _newMember,
        uint256 _couponAmount,
        uint256 _membershipDuration
    ) internal view returns (Client.EVM2AnyMessage memory _message) {
        MessageBuild memory messageBuild = MessageBuild({
            token: _tokenToTransfer,
            amount: _amountToTransfer,
            gasLimit: _gasLimit,
            contribution: _contributionAmount,
            parent: _parent,
            newMember: _newMember,
            couponAmount: _couponAmount,
            membershipDuration: _membershipDuration
        });
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        _message = _buildCCIPMessage(messageBuild);
    }

    function _feeChecks(
        Client.EVM2AnyMessage memory _message
    ) internal returns (uint256 _ccipFees) {
        // Fee required to send the message
        _ccipFees = router.getFee(destinationChainSelector, _message);

        uint256 _linkBalance = linkToken.balanceOf(address(this));

        if (_ccipFees > _linkBalance)
            revert TLDCcipSender__NotEnoughBalance(_linkBalance, _ccipFees);

        // Approve the Router to transfer LINK tokens from this contract if needed
        linkToken.approve(address(router), _ccipFees);
    }

    function _sendMessage(
        address _newMember,
        uint256 _amountToTransfer,
        address _tokenToTransfer,
        uint256 _ccipFees,
        Client.EVM2AnyMessage memory _message
    ) internal returns (bytes32 _messageId) {
        IERC20(_tokenToTransfer).safeTransferFrom(_newMember, address(this), _amountToTransfer);
        IERC20(_tokenToTransfer).approve(address(router), _amountToTransfer);

        // Send the message through the router and store the returned message ID
        _messageId = router.ccipSend(destinationChainSelector, _message);

        // Emit an event with message details
        emit OnTokensTransferred(
            _messageId,
            _amountToTransfer,
            _ccipFees,
            _newMember,
            isPrejoinEnabled
        );
    }

    function _buildCCIPMessage(
        MessageBuild memory _messageBuild
    ) internal view returns (Client.EVM2AnyMessage memory) {
        // Set the token amounts
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: _messageBuild.token,
            amount: _messageBuild.amount
        });

        bytes memory dataToSend;

        // Function to call in the receiver contract
        if (isPrejoinEnabled) {
            // payContributionOnBehalfOf(uint256 contribution, address parent, address newMember, uint256 couponAmount)
            dataToSend = abi.encodeWithSignature(
                "payContributionOnBehalfOf(uint256,address,address,uint256)",
                _messageBuild.contribution,
                _messageBuild.parent,
                _messageBuild.newMember,
                _messageBuild.couponAmount
            );
        } else {
            // joinPoolOnBehalfOf(address membersWallet, address parentWallet, uint256 contributionBeforeFee, uint256 membershipDuration, uint256 couponAmount)
            dataToSend = abi.encodeWithSignature(
                "joinPoolOnBehalfOf(address,address,uint256,uint256,uint256)",
                _messageBuild.newMember,
                _messageBuild.parent,
                _messageBuild.contribution,
                _messageBuild.membershipDuration,
                _messageBuild.couponAmount
            );
        }

        // EVM2AnyMessage struct
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiverContract),
            data: dataToSend,
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({
                    gasLimit: _messageBuild.gasLimit,
                    allowOutOfOrderExecution: true
                })
            ),
            feeToken: address(linkToken)
        });

        return message;
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
