// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

contract MockUniV3Pool {
    address public token0;
    address public token1;

    uint160 public sqrtPriceX96;
    int24 public twapTick;
    bool public observeShouldRevert;

    constructor(address token0_, address token1_, uint160 sqrtPriceX96_) {
        token0 = token0_;
        token1 = token1_;
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function setSqrtPriceX96(uint160 newSqrtPriceX96) external {
        sqrtPriceX96 = newSqrtPriceX96;
    }

    function setTwapTick(int24 newTwapTick) external {
        twapTick = newTwapTick;
    }

    function setObserveRevert(bool shouldRevert) external {
        observeShouldRevert = shouldRevert;
    }

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96_,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        sqrtPriceX96_ = sqrtPriceX96;
        tick = 0;
        observationIndex = 0;
        observationCardinality = 0;
        observationCardinalityNext = 0;
        feeProtocol = 0;
        unlocked = true;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        if (observeShouldRevert) revert("MOCK_OBSERVE_REVERT");

        uint32 window = secondsAgos.length > 0 ? secondsAgos[0] : 0;

        tickCumulatives = new int56[](2);
        secondsPerLiquidityCumulativeX128s = new uint160[](2);

        int56 delta = int56(int256(int24(twapTick)) * int256(uint256(window)));
        tickCumulatives[0] = 0;
        tickCumulatives[1] = delta;
    }

    function test() public view {}
}
