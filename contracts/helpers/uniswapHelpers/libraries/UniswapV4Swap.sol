// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

library UniswapV4Swap {
    bytes1 internal constant ACTION_SWAP_EXACT_IN_SINGLE = 0x06;
    bytes1 internal constant ACTION_SETTLE_ALL = 0x0c;
    bytes1 internal constant ACTION_TAKE_ALL = 0x0f;

    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    function buildPoolKey(address _tokenA, address _tokenB, uint24 _fee, int24 _tickSpacing, address _hooks)
        internal
        pure
        returns (PoolKey memory poolKey_)
    {
        if (_tokenA < _tokenB) {
            poolKey_ = PoolKey({
                currency0: _tokenA,
                currency1: _tokenB,
                fee: _fee,
                tickSpacing: _tickSpacing,
                hooks: _hooks
            });
        } else {
            poolKey_ = PoolKey({
                currency0: _tokenB,
                currency1: _tokenA,
                fee: _fee,
                tickSpacing: _tickSpacing,
                hooks: _hooks
            });
        }
    }

    function computePoolId(PoolKey memory _poolKey) internal pure returns (bytes32 poolId_) {
        poolId_ = keccak256(abi.encode(_poolKey));
    }

    function buildUniversalRouterExactInSingleInput(
        PoolKey memory _poolKey,
        bool _zeroForOne,
        uint128 _amountIn,
        uint128 _amountOutMinimum,
        uint256 _maxInputSettleAmount,
        uint256 _minOutputTakeAmount
    ) internal pure returns (bytes memory input_) {
        bytes memory actions =
            abi.encodePacked(ACTION_SWAP_EXACT_IN_SINGLE, ACTION_SETTLE_ALL, ACTION_TAKE_ALL);

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
