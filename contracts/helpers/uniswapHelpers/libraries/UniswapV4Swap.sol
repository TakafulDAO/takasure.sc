// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/**
 * @title UniswapV4Swap
 * @notice Shared helpers for building Uniswap V4 pool metadata and Universal Router swap payloads.
 */
library UniswapV4Swap {
    bytes1 internal constant ACTION_SWAP_EXACT_IN_SINGLE = 0x06;
    bytes1 internal constant ACTION_SETTLE_ALL = 0x0c;
    bytes1 internal constant ACTION_TAKE_ALL = 0x0f;

    /// @dev Minimal Uniswap V4 pool descriptor used by the Universal Router exact-in-single flow.
    struct PoolKey {
        address currency0; // Lower-sorted token address.
        address currency1; // Higher-sorted token address.
        uint24 fee; // Pool LP fee in hundredths of a bip.
        int24 tickSpacing; // Tick spacing configured by the pool.
        address hooks; // Hook contract configured for the pool, or address(0).
    }

    /// @dev Parameters expected by the V4 exact-in-single action inside the Universal Router.
    struct ExactInputSingleParams {
        PoolKey poolKey; // Target V4 pool.
        bool zeroForOne; // True when swapping currency0 into currency1.
        uint128 amountIn; // Exact input amount.
        uint128 amountOutMinimum; // Slippage floor enforced by the router.
        bytes hookData; // Extra hook calldata; empty for this strategy flow.
    }

    /**
     * @dev Builds a V4 `PoolKey` with currencies sorted by address.
     * @param _tokenA First token address in arbitrary order.
     * @param _tokenB Second token address in arbitrary order.
     * @param _fee Pool LP fee in hundredths of a bip.
     * @param _tickSpacing Tick spacing configured by the pool.
     * @param _hooks Hook contract address configured by the pool, or address(0).
     * @return poolKey_ Canonically ordered pool key suitable for pool-id computation and router inputs.
     */
    function buildPoolKey(address _tokenA, address _tokenB, uint24 _fee, int24 _tickSpacing, address _hooks)
        internal
        pure
        returns (PoolKey memory poolKey_)
    {
        if (_tokenA < _tokenB) {
            poolKey_ = PoolKey({
                currency0: _tokenA, currency1: _tokenB, fee: _fee, tickSpacing: _tickSpacing, hooks: _hooks
            });
        } else {
            poolKey_ =
                PoolKey({currency0: _tokenB, currency1: _tokenA, fee: _fee, tickSpacing: _tickSpacing, hooks: _hooks});
        }
    }

    /**
     * @dev Computes the Uniswap V4 pool id for the provided `PoolKey`.
     * @param _poolKey Canonically ordered V4 pool key.
     * @return poolId_ Keccak256 hash of the ABI-encoded pool key.
     */
    function computePoolId(PoolKey memory _poolKey) internal pure returns (bytes32 poolId_) {
        poolId_ = keccak256(abi.encode(_poolKey));
    }

    /**
     * @dev Builds the Universal Router input for a single-hop V4 exact-in swap followed by settle/take actions.
     * @param _poolKey Target V4 pool key.
     * @param _zeroForOne True when swapping `currency0 -> currency1`, false for the inverse direction.
     * @param _amountIn Exact input amount forwarded into the swap action.
     * @param _amountOutMinimum Minimum output accepted by the swap action.
     * @param _maxInputSettleAmount Maximum amount settled for the input currency in `SETTLE_ALL`.
     * @param _minOutputTakeAmount Minimum amount taken for the output currency in `TAKE_ALL`.
     * @return input_ ABI-encoded Universal Router payload `(bytes actions, bytes[] params)`.
     */
    function buildUniversalRouterExactInSingleInput(
        PoolKey memory _poolKey,
        bool _zeroForOne,
        uint128 _amountIn,
        uint128 _amountOutMinimum,
        uint256 _maxInputSettleAmount,
        uint256 _minOutputTakeAmount
    ) internal pure returns (bytes memory input_) {
        bytes memory actions = abi.encodePacked(ACTION_SWAP_EXACT_IN_SINGLE, ACTION_SETTLE_ALL, ACTION_TAKE_ALL);

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: _poolKey,
                zeroForOne: _zeroForOne,
                amountIn: _amountIn,
                amountOutMinimum: _amountOutMinimum,
                hookData: bytes("")
            })
        );

        address inputCurrency = _zeroForOne ? _poolKey.currency0 : _poolKey.currency1;
        address outputCurrency = _zeroForOne ? _poolKey.currency1 : _poolKey.currency0;

        params[1] = abi.encode(inputCurrency, _maxInputSettleAmount);
        params[2] = abi.encode(outputCurrency, _minOutputTakeAmount);

        input_ = abi.encode(actions, params);
    }
}
