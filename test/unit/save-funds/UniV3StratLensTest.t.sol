// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SFUniswapV3StrategyLens} from "contracts/saveFunds/SFUniswapV3StrategyLens.sol";
import {StrategyConfig} from "contracts/types/Strategies.sol";

import {TestERC20} from "test/mocks/TestERC20.sol";
import {MockUniV3Pool} from "test/mocks/MockUniV3Pool.sol";
import {MockUniV3StrategyLensTarget} from "test/mocks/MockUniV3StrategyLensTarget.sol";

contract UniV3StratLensTest is Test {
    SFUniswapV3StrategyLens internal lens;

    TestERC20 internal token0;
    TestERC20 internal token1;
    TestERC20 internal token2;

    MockUniV3Pool internal pool;

    MockUniV3StrategyLensTarget internal stratToken0Asset;
    MockUniV3StrategyLensTarget internal stratToken1Asset;

    uint160 internal constant PRICE_ONE = uint160(1) << 96;
    uint160 internal constant PRICE_FOUR = uint160(1) << 97; // price = 4

    function setUp() public {
        lens = new SFUniswapV3StrategyLens();

        token0 = new TestERC20("Token0", "TK0", 18);
        token1 = new TestERC20("Token1", "TK1", 18);
        token2 = new TestERC20("Token2", "TK2", 18);

        pool = new MockUniV3Pool(address(token0), address(token1), PRICE_FOUR);

        stratToken0Asset =
            new MockUniV3StrategyLensTarget(address(token0), address(token1), address(pool), address(0xBEEF));
        stratToken1Asset =
            new MockUniV3StrategyLensTarget(address(token1), address(token0), address(pool), address(0xBEEF));
    }

    function testUniV3StratLens_getConfig_ReturnsExpected() public {
        stratToken0Asset.setPaused(true);

        StrategyConfig memory cfg = lens.getConfig(address(stratToken0Asset));

        assertEq(cfg.asset, address(token0));
        assertEq(cfg.vault, address(0xBEEF));
        assertEq(cfg.pool, address(pool));
        assertTrue(cfg.paused);
    }

    function testUniV3StratLens_getPositionDetails_Encodes() public {
        stratToken0Asset.setPositionTokenId(123);
        stratToken0Asset.setTicks(-120, 120);

        (uint8 version, uint256 tokenId, address poolAddr, int24 lower, int24 upper) =
            abi.decode(lens.getPositionDetails(address(stratToken0Asset)), (uint8, uint256, address, int24, int24));

        assertEq(version, 1);
        assertEq(tokenId, 123);
        assertEq(poolAddr, address(pool));
        assertEq(lower, -120);
        assertEq(upper, 120);
    }

    function testUniV3StratLens_positionValue_ReturnsZeroWhenTotalZero() public {
        stratToken0Asset.setTotalAssets(0);
        uint256 value = lens.positionValue(address(stratToken0Asset));
        assertEq(value, 0);
    }

    function testUniV3StratLens_positionValue_ReturnsZeroWhenTotalLessOrEqualIdle() public {
        pool.setSqrtPriceX96(PRICE_ONE);
        stratToken0Asset.setTwapWindow(0);
        stratToken0Asset.setTotalAssets(100);

        token0.mint(address(stratToken0Asset), 60);
        token1.mint(address(stratToken0Asset), 60);

        uint256 value = lens.positionValue(address(stratToken0Asset));
        assertEq(value, 0);
    }

    function testUniV3StratLens_positionValue_ReturnsPositionValueWhenTotalGreaterThanIdle() public {
        pool.setSqrtPriceX96(PRICE_ONE);
        stratToken0Asset.setTwapWindow(0);
        stratToken0Asset.setTotalAssets(200);

        token0.mint(address(stratToken0Asset), 50);
        token1.mint(address(stratToken0Asset), 50);

        uint256 value = lens.positionValue(address(stratToken0Asset));
        assertEq(value, 100);
    }

    function testUniV3StratLens_positionValue_UsesSpotWhenWindowZero() public {
        pool.setSqrtPriceX96(PRICE_FOUR);
        stratToken1Asset.setTwapWindow(0);
        stratToken1Asset.setTotalAssets(150);

        token0.mint(address(stratToken1Asset), 50);

        uint256 value = lens.positionValue(address(stratToken1Asset));
        assertEq(value, 0);
    }

    function testUniV3StratLens_positionValue_UsesTwapWhenWindowSet() public {
        pool.setSqrtPriceX96(PRICE_FOUR);
        pool.setTwapTick(0); // price = 1
        stratToken1Asset.setTwapWindow(60);
        stratToken1Asset.setTotalAssets(150);

        token0.mint(address(stratToken1Asset), 50);

        uint256 value = lens.positionValue(address(stratToken1Asset));
        assertEq(value, 100);
    }

    function testUniV3StratLens_positionValue_AllowsUnderlyingEqualsOther() public {
        MockUniV3StrategyLensTarget sameToken =
            new MockUniV3StrategyLensTarget(address(token0), address(token0), address(pool), address(0xBEEF));

        sameToken.setTwapWindow(0);
        sameToken.setTotalAssets(30);
        token0.mint(address(sameToken), 10);

        uint256 value = lens.positionValue(address(sameToken));
        assertEq(value, 10);
    }

    function testUniV3StratLens_positionValue_RevertsIfPoolTokensMismatch() public {
        MockUniV3Pool badPool = new MockUniV3Pool(address(token2), address(token1), PRICE_ONE);
        MockUniV3StrategyLensTarget bad =
            new MockUniV3StrategyLensTarget(address(token0), address(token1), address(badPool), address(0xBEEF));

        bad.setTwapWindow(0);
        bad.setTotalAssets(50);
        token1.mint(address(bad), 10);

        vm.expectRevert();
        lens.positionValue(address(bad));
    }
}
