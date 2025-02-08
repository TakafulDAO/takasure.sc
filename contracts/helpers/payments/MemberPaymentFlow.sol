//SPDX-License-Identifier: GPL-3.0

import {Reserve} from "contracts/types/TakasureTypes.sol";
import {CashFlowAlgorithms} from "contracts/helpers/libraries/algorithms/CashFlowAlgorithms.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

abstract contract MemberPaymentFlow {
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

    function _transferContribution(
        IERC20 _contributionToken,
        address _memberWallet,
        address _takasureReserve,
        uint256 _contributionAfterFee
    ) internal virtual {
        _contributionToken.safeTransferFrom(_memberWallet, _takasureReserve, _contributionAfterFee);
    }
}
