//SPDX-License-Identifier: GNU GPLv3

/**
 * @title UsdcFaucet
 * @author Maikel Ordaz
 * @notice This contract will:
 *          - Help the dev team to get the test USDC tokens in different chains
 *          - Deployed in Ethereum Sepolia
 *          - For Ethereum sepolia will be a direct transfer
 *          - For other chains will be a CCIP transfer
 *          - The limit is only the contract balance
 * @dev Upgradeable contract with UUPS pattern
 */

pragma solidity 0.8.28;

import {IRouterClient} from "ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Client} from "ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @custom:oz-upgrades-from contracts/version_previous_contracts/TLDCcipSenderV1.sol:TLDCcipSenderV1
contract UsdcFaucet is Ownable2Step {
    using SafeERC20 for IERC20;

    IRouterClient private router;
    IERC20 public immutable linkToken;
    IERC20 public immutable usdc;

    uint256 private constant GAS_LIMIT = 400_000;

    /*//////////////////////////////////////////////////////////////
                            EVENTS & ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnTokensTransferred(bytes32 indexed messageId, uint256 indexed tokenAmount, uint256 fees);

    error UsdcFaucet__NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error UsdcFaucet__NothingToWithdraw();
    error UsdcFaucet__AddressZeroNotAllowed();
    error UsdcFaucet__NotAllowedChain();
    error UsdcFaucet__NotEnoughUsdcBalance();

    modifier notZeroAddress(address addressToCheck) {
        require(addressToCheck != address(0), UsdcFaucet__AddressZeroNotAllowed());
        _;
    }

    constructor(address _router, address _link, address _usdc) Ownable(msg.sender) {
        router = IRouterClient(_router);
        linkToken = IERC20(_link);
        usdc = IERC20(_usdc);

        usdc.approve(_router, type(uint256).max);
    }

    function mintUsdc(
        uint256 amountToTransfer,
        string calldata destinationChain,
        address receiver
    ) external returns (bytes32 messageId) {
        require(
            amountToTransfer <= usdc.balanceOf(address(this)),
            UsdcFaucet__NotEnoughUsdcBalance()
        );
        Client.EVM2AnyMessage memory message = _buildCCIPMessage({
            _amount: amountToTransfer,
            _receiver: receiver
        });

        uint64 destinationChainSelector;

        if (Strings.equal(destinationChain, "base")) {
            destinationChainSelector = 10344971235874465080;
        } else if (Strings.equal(destinationChain, "eth")) {
            usdc.transfer(receiver, amountToTransfer);
            return 0;
        } else if (Strings.equal(destinationChain, "opt")) {
            destinationChainSelector = 5224473277236331295;
        } else if (Strings.equal(destinationChain, "pol")) {
            destinationChainSelector = 16281711391670634445;
        } else {
            revert UsdcFaucet__NotAllowedChain();
        }

        uint256 ccipFees = _feeChecks(message, destinationChainSelector);

        messageId = _sendMessage({
            _amountToTransfer: amountToTransfer,
            _ccipFees: ccipFees,
            _destinationChainSelector: destinationChainSelector,
            _message: message
        });
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/

    function withdrawToken(address token) external onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = IERC20(token).balanceOf(address(this));

        // Revert if there is nothing to withdraw
        if (amount == 0) revert UsdcFaucet__NothingToWithdraw();

        IERC20(token).safeTransfer(owner(), amount);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _feeChecks(
        Client.EVM2AnyMessage memory _message,
        uint64 _destinationChainSelector
    ) internal returns (uint256 _ccipFees) {
        // Fee required to send the message
        _ccipFees = router.getFee(_destinationChainSelector, _message);

        uint256 _linkBalance = linkToken.balanceOf(address(this));

        if (_ccipFees > _linkBalance) revert UsdcFaucet__NotEnoughBalance(_linkBalance, _ccipFees);

        // Approve the Router to transfer LINK tokens from this contract if needed
        linkToken.approve(address(router), _ccipFees);
    }

    function _sendMessage(
        uint256 _amountToTransfer,
        uint256 _ccipFees,
        uint64 _destinationChainSelector,
        Client.EVM2AnyMessage memory _message
    ) internal returns (bytes32 _messageId) {
        // Send the message through the router and store the returned message ID
        _messageId = router.ccipSend(_destinationChainSelector, _message);

        // Emit an event with message details
        emit OnTokensTransferred(_messageId, _amountToTransfer, _ccipFees);
    }

    function _buildCCIPMessage(
        uint256 _amount,
        address _receiver
    ) internal view returns (Client.EVM2AnyMessage memory) {
        // Set the token amounts
        Client.EVMTokenAmount[] memory _tokenAmounts = new Client.EVMTokenAmount[](1);
        _tokenAmounts[0] = Client.EVMTokenAmount({token: address(usdc), amount: _amount});

        // EVM2AnyMessage struct
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            data: "",
            tokenAmounts: _tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({gasLimit: GAS_LIMIT, allowOutOfOrderExecution: true})
            ),
            feeToken: address(linkToken)
        });

        return message;
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
