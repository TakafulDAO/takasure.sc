// SPDX-License-Identifier: GPL-3.0-or-later

/**
 * @title UniswapV3Swap
 * @author Maikel Ordaz
 * @notice Shared helpers for building direct Uniswap V3 paths and Universal Router swap inputs.
 */

pragma solidity 0.8.28;

library UniswapV3Swap {
    /**
     * @dev Builds a single-hop Uniswap V3 path.
     * @param _tokenIn Input token address.
     * @param _fee Pool fee for the hop.
     * @param _tokenOut Output token address.
     * @return path_ ABI-packed V3 path bytes.
     */
    function buildSingleHopPath(address _tokenIn, uint24 _fee, address _tokenOut)
        internal
        pure
        returns (bytes memory path_)
    {
        path_ = abi.encodePacked(_tokenIn, _fee, _tokenOut);
    }

    /**
     * @dev Builds Universal Router input for a `Commands.V3_SWAP_EXACT_IN` action.
     * @param _recipient Recipient of the swap output.
     * @param _amountIn Exact input amount.
     * @param _amountOutMin Minimum accepted output amount.
     * @param _path Packed Uniswap V3 path bytes.
     * @param _payerIsUser Whether Permit2 should source funds from the caller.
     * @return input_ ABI-encoded Universal Router input.
     */
    function buildUniversalRouterExactInInput(
        address _recipient,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes memory _path,
        bool _payerIsUser
    ) internal pure returns (bytes memory input_) {
        input_ = abi.encode(_recipient, _amountIn, _amountOutMin, _path, _payerIsUser);
    }
}
