//SPDX-License-Identifier: GPL-3.0

/**
 * @title MemberPaymentFlow
 * @author Maikel Ordaz
 * @notice This contract will run thhe needed algorithms when a user performs a payment
 * @dev The logic in this contract will be different according to the module that is using it:
 *      1. EntryModule:
 *          1.1 Will fetch first the Benefit Multiplier for the user.
 *          1.2 Then it will run the algorithms to update the reserves and mint the DAO Tokens
 *          1.3 As in joining the user first transfer to the module, and when it is KYCed the module will transfer
 *              the contribution to the reserves, the transfer will be done from the module to the reserves
 *      2. MemberModule: Will run the functions as written here
 */

import {Reserve} from "contracts/types/TakasureTypes.sol";
import {CashFlowAlgorithms} from "contracts/helpers/libraries/algorithms/CashFlowAlgorithms.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract MemberPaymentFlow {
    using SafeERC20 for IERC20;

    /**
     * @notice This function will update all the variables needed when a member pays the contribution
     * @dev It transfer the contribution from the module to the reserves
     */
    function _memberPaymentFlow(
        uint256 _contributionBeforeFee,
        uint256 _contributionAfterFee,
        address _memberWallet,
        Reserve memory _reserve,
        ITakasureReserve _takasureReserve
    ) internal virtual returns (Reserve memory, uint256) {
        _reserve = CashFlowAlgorithms._updateNewReserveValues(
            _takasureReserve,
            _contributionAfterFee,
            _contributionBeforeFee,
            _reserve
        );

        // Transfer the contribution to the reserves
        _transferContribution(
            IERC20(_reserve.contributionToken),
            _memberWallet,
            address(_takasureReserve),
            _contributionAfterFee
        );

        // Mint the DAO Tokens
        uint256 mintedTokens_ = CashFlowAlgorithms._mintDaoTokens(
            _takasureReserve,
            _contributionBeforeFee
        );

        return (_reserve, mintedTokens_);
    }

    /**
     * @notice This function will transfer the contribution from the module to the reserves
     * @dev Override in module if the transfer is handled differently
     */
    function _transferContribution(
        IERC20 _contributionToken,
        address _memberWallet,
        address _takasureReserve,
        uint256 _contributionAfterFee
    ) internal virtual {
        _contributionToken.safeTransferFrom(_memberWallet, _takasureReserve, _contributionAfterFee);
    }
}
