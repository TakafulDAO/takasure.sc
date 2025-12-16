// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFUniswapV3Strategy
 * @author Maikel Ordaz
 * @notice Uniswap V3 strategy implementation for SaveFunds vaults.
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {ISFStrategyView} from "contracts/interfaces/saveFunds/ISFStrategyView.sol";
import {ISFStrategyMaintenance} from "contracts/interfaces/saveFunds/ISFStrategyMaintenance.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "contracts/interfaces/saveFunds/INonfungiblePositionManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {StrategyConfig} from "contracts/types/TakasureTypes.sol";
import {LiquidityAmountsV3 as LiquidityAmounts} from "contracts/helpers/libraries/uniswap/LiquidityAmountsV3.sol";
import {TickMathV3 as TickMath} from "contracts/helpers/libraries/uniswap/TickMathV3.sol";

pragma solidity 0.8.28;

contract SFUniswapV3Strategy is
    ISFStrategy,
    ISFStrategyView,
    ISFStrategyMaintenance,
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    PausableUpgradeable
{
    IAddressManager public addressManager;
    IUniswapV3Pool public pool;
    INonfungiblePositionManager public positionManager;

    IERC20 public underlying; // USDC
    IERC20 public otherToken; // USDT or any other token paired in the pool with USDC
    address public vault;

    uint256 public maxTVL;
    uint256 public positionTokenId; // LP NFT ID, ideally owned by vault
    int24 public tickLower;
    int24 public tickUpper;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    error SFUniswapV3Strategy__NotAuthorizedCaller();
    error SFUniswapV3Strategy__NotAddressZero();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyRole(bytes32 role, address addressManagerAddress) {
        require(
            IAddressManager(addressManagerAddress).hasRole(role, msg.sender), SFUniswapV3Strategy__NotAuthorizedCaller()
        );
        _;
    }

    modifier notAddressZero(address addr) {
        require(addr != address(0), SFUniswapV3Strategy__NotAddressZero());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IAddressManager _addressManager,
        address _vault,
        IERC20 _underlying,
        IERC20 _otherToken,
        address _pool,
        address _positionManager,
        uint256 _maxTVL
    ) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        __Pausable_init();

        addressManager = _addressManager;
        vault = _vault;
        underlying = _underlying;
        otherToken = _otherToken;
        pool = IUniswapV3Pool(_pool);
        positionManager = INonfungiblePositionManager(_positionManager);
        maxTVL = _maxTVL;
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyRole(Roles.PAUSE_GUARDIAN, address(addressManager)) {
        _pause();
    }

    function unpause() external onlyRole(Roles.PAUSE_GUARDIAN, address(addressManager)) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the underlying asset address managed by the strategy.
     * @return Address of the underlying asset.
     */
    function asset() external view returns (address) {
        return address(underlying);
    }

    function totalAssets() public view returns (uint256) {
        // Value of LP position + idle balances in USDC terms
        uint256 value = _positionValue();

        uint256 idleUnderlying = underlying.balanceOf(address(this));
        uint256 idleOther = otherToken.balanceOf(address(this));

        if (idleUnderlying > 0) value += idleUnderlying;

        if (idleOther > 0) {
            // todo: convert idleOther -> USDC using pool price or twap or off chain oracle
            uint256 otherInUSDC = _quoteOtherAsUnderlying(idleOther);
            value += otherInUSDC;
        }

        return value;
    }

    function maxDeposit() external view returns (uint256) {
        if (maxTVL == 0) return type(uint256).max;

        uint256 current = totalAssets();
        if (current >= maxTVL) return 0;

        return maxTVL - current;
    }

    function maxWithdraw() external view returns (uint256) {
        // todo: check
        return totalAssets();
    }

    function getConfig() external view returns (StrategyConfig memory) {
        return StrategyConfig({
            asset: address(underlying), vault: vault, pool: address(pool), maxTVL: maxTVL, paused: paused()
        });
    }

    function positionValue() external view returns (uint256) {
        // Only the LP; excludes idle balances.
        return _positionValue();
    }

    function getPositionDetails() external view returns (bytes memory) {
        // todo: revisit. Implementation-specific. For now: (tokenId, tickLower, tickUpper)
        return abi.encode(positionTokenId, tickLower, tickUpper);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _positionValue() internal view returns (uint256) {
        if (positionTokenId == 0) return 0;

        (,, address _token0, address _token1,, int24 _tickLower, int24 _tickUpper, uint128 _liquidity,,,,) =
            positionManager.positions(positionTokenId);

        if (_liquidity == 0) return 0;

        (uint160 _sqrtPriceX96,,,,,,) = pool.slot0();

        // Compute amounts of token0 and token1 for given liquidity and ticks
        (uint256 _amount0, uint256 _amount1) = LiquidityAmounts.getAmountsForLiquidity(
            _sqrtPriceX96, TickMath.getSqrtRatioAtTick(_tickLower), TickMath.getSqrtRatioAtTick(_tickUpper), _liquidity
        );

        uint256 _value;

        // Map amounts to USDC
        if (_token0 == address(underlying)) _value += _amount0;
        else if (_token0 == address(otherToken)) _value += _quoteOtherAsUnderlying(_amount0);

        if (_token1 == address(underlying)) _value += _amount1;
        else if (_token1 == address(otherToken)) _value += _quoteOtherAsUnderlying(_amount1);

        return _value;
    }

    function _quoteOtherAsUnderlying(uint256 _amountOther) internal pure returns (uint256) {
        // todo: compute via pool.slot0 or twap and convert amountOther -> USDC units
        return _amountOther;
    }

    /// @dev required by the OZ UUPS module.
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(Roles.OPERATOR, address(addressManager))
    {}

    // todo: implement
    function withdraw(uint256 assets, address receiver, bytes calldata data)
        external
        returns (uint256 withdrawnAssets)
    {}
    function setMaxTVL(uint256 newMaxTVL) external {}
    function setConfig(bytes calldata newConfig) external {}
    function emergencyExit(address receiver) external {}
    function deposit(uint256 assets, bytes calldata data) external returns (uint256 investedAssets) {}
    function rebalance(bytes calldata data) external {}
    function harvest(bytes calldata data) external {}
}
