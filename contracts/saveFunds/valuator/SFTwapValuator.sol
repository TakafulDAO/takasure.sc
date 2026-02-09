// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFTwapValuator
 * @author Maikel Ordaz
 * @notice Uniswap V3 TWAP/spot valuator for SaveFunds vaults.
 */

pragma solidity 0.8.28;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {TickMathV3} from "contracts/helpers/uniswapHelpers/libraries/TickMathV3.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract SFTwapValuator {
    IAddressManager public addressManager;
    mapping(address token => address pool) public valuationPool;
    uint32 public twapWindow; // seconds; 0 => spot

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnValuationPoolSet(address indexed token, address indexed pool);
    event OnTwapWindowUpdated(uint32 oldWindow, uint32 newWindow);

    error SFTwapValuator__NotAuthorizedCaller();
    error SFTwapValuator__NotAddressZero();
    error SFTwapValuator__InvalidValuationPool();
    error SFTwapValuator__InvalidTwapWindow();
    error SFTwapValuator__ValuationPoolNotSet();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyRole(bytes32 role) {
        require(addressManager.hasRole(role, msg.sender), SFTwapValuator__NotAuthorizedCaller());
        _;
    }

    modifier notAddressZero(address addr) {
        require(addr != address(0), SFTwapValuator__NotAddressZero());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(IAddressManager _addressManager, uint32 _twapWindow) notAddressZero(address(_addressManager)) {
        addressManager = _addressManager;
        _setTwapWindow(_twapWindow);
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    function setValuationPool(address token, address pool) external onlyRole(Roles.OPERATOR) notAddressZero(token) {
        require(pool != address(0), SFTwapValuator__InvalidValuationPool());

        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();
        require(token0 == token || token1 == token, SFTwapValuator__InvalidValuationPool());

        valuationPool[token] = pool;
        emit OnValuationPoolSet(token, pool);
    }

    function setTwapWindow(uint32 newWindow) external onlyRole(Roles.OPERATOR) {
        _setTwapWindow(newWindow);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function quote(address token, uint256 amount, address underlying) external view returns (uint256) {
        if (token == underlying) return amount;
        if (amount == 0) return 0;

        address pool = valuationPool[token];
        require(pool != address(0), SFTwapValuator__ValuationPoolNotSet());

        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();
        require(
            (token0 == token && token1 == underlying) || (token1 == token && token0 == underlying),
            SFTwapValuator__InvalidValuationPool()
        );

        uint160 sqrtPriceX96 = _valuationSqrtPriceX96(pool);

        // price = token1/token0 = (sqrtPriceX96^2) / 2^192
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 q192 = 1 << 192;

        if (token == token0 && underlying == token1) {
            // token is token0, underlying is token1 -> amount * price
            return Math.mulDiv(amount, priceX192, q192);
        } else {
            // token is token1, underlying is token0 -> amount / price
            return Math.mulDiv(amount, q192, priceX192);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _setTwapWindow(uint32 newWindow) internal {
        require(newWindow == 0 || newWindow >= 60, SFTwapValuator__InvalidTwapWindow());
        uint32 old = twapWindow;
        twapWindow = newWindow;
        emit OnTwapWindowUpdated(old, newWindow);
    }

    function _valuationSqrtPriceX96(address pool) internal view returns (uint160 sqrtPriceX96_) {
        uint32 window = twapWindow;
        IUniswapV3Pool uniPool = IUniswapV3Pool(pool);

        // Spot mode
        if (window == 0) {
            (sqrtPriceX96_,,,,,,) = uniPool.slot0();
            return sqrtPriceX96_;
        }

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;

        // TWAP mode, fallback to spot if observe fails
        try uniPool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int56 secs = int56(uint56(window));

            int24 avgTick = int24(delta / secs);
            if (delta < 0 && (delta % secs != 0)) avgTick--;

            sqrtPriceX96_ = TickMathV3.getSqrtRatioAtTick(avgTick);
            return sqrtPriceX96_;
        } catch {
            (sqrtPriceX96_,,,,,,) = uniPool.slot0();
            return sqrtPriceX96_;
        }
    }
}
