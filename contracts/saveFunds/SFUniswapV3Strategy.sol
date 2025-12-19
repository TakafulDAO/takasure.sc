// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFUniswapV3Strategy
 * @author Maikel Ordaz
 * @notice Uniswap V3 strategy implementation for SaveFunds vaults.
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ISFVault} from "contracts/interfaces/saveFunds/ISFVault.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {ISFStrategyView} from "contracts/interfaces/saveFunds/ISFStrategyView.sol";
import {ISFStrategyMaintenance} from "contracts/interfaces/saveFunds/ISFStrategyMaintenance.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "contracts/interfaces/helpers/INonfungiblePositionManager.sol";
import {IUniversalRouter} from "contracts/interfaces/helpers/IUniversalRouter.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {StrategyConfig} from "contracts/types/Strategies.sol";
import {LiquidityAmountsV3 as LiquidityAmounts} from "contracts/helpers/libraries/uniswap/LiquidityAmountsV3.sol";
import {TickMathV3 as TickMath} from "contracts/helpers/libraries/uniswap/TickMathV3.sol";
import {FullMathV3 as FullMath} from "contracts/helpers/libraries/uniswap/FullMathV3.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Commands} from "contracts/helpers/libraries/uniswap/Commands.sol";
import {PositionReader} from "contracts/helpers/libraries/uniswap/PositionReader.sol";

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
    using SafeERC20 for IERC20;

    uint16 internal constant MAX_BPS = 10_000;

    IAddressManager public addressManager;
    IUniswapV3Pool public pool;
    INonfungiblePositionManager public positionManager;
    IUniversalRouter public universalRouter;

    IERC20 public underlying; // USDC
    IERC20 public otherToken; // USDT or any other token paired in the pool with USDC
    address public vault;
    address public token0;
    address public token1;

    uint256 public maxTVL;
    uint256 public positionTokenId; // LP NFT ID, ideally owned by vault
    int24 public tickLower;
    int24 public tickUpper;
    uint32 public twapWindow; // seconds; 0 => spot

    struct V3ActionData {
        uint16 otherRatioBPS; // 0..10000 (default 5000)
        bytes swapToOtherData; // abi.encode(bytes[] inputs, uint256 deadline) for underlying->otherToken
        bytes swapToUnderlyingData; // abi.encode(bytes[] inputs, uint256 deadline) for otherToken->underlying
        uint256 pmDeadline; // deadline for positionManager mint/increase/decrease
        uint256 minUnderlying; // slippage floor for underlying side in mint/increase/decrease
        uint256 minOther; // slippage floor for otherToken side in mint/increase/decrease
    }

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnMaxTVLUpdated(uint256 oldMaxTVL, uint256 newMaxTVL);
    event TwapWindowUpdated(uint32 oldWindow, uint32 newWindow);

    error SFUniswapV3Strategy__NotAuthorizedCaller();
    error SFUniswapV3Strategy__NotAddressZero();
    error SFUniswapV3Strategy__NotZeroAmount();
    error SFUniswapV3Strategy__MaxTVLReached();
    error SFUniswapV3Strategy__InvalidPoolTokens();
    error SFUniswapV3Strategy__UnexpectedPositionTokenId();
    error SFUniswapV3Strategy__InvalidRebalanceParams();
    error SFUniswapV3Strategy__InvalidTicks();
    error SFUniswapV3Strategy__VaultNotApprovedForNFT();
    error SFUniswapV3Strategy__InvalidStrategyData();
    error SFUniswapV3Strategy__NoPosition();
    error SFUniswapV3Strategy__InvalidTwapWindow();
    error SFUniswapV3Strategy__InvalidDeadline();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyRole(bytes32 role) {
        require(addressManager.hasRole(role, msg.sender), SFUniswapV3Strategy__NotAuthorizedCaller());
        _;
    }

    modifier onlyContract(string memory name) {
        require(addressManager.hasName(name, msg.sender), SFUniswapV3Strategy__NotAuthorizedCaller());
        _;
    }

    modifier onlyKeeperOrOperator() {
        require(
            IAddressManager(addressManager).hasRole(Roles.KEEPER, msg.sender)
                || IAddressManager(addressManager).hasRole(Roles.OPERATOR, msg.sender),
            SFUniswapV3Strategy__NotAuthorizedCaller()
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
        uint256 _maxTVL,
        address _router,
        int24 _tickLower,
        int24 _tickUpper
    ) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        __Pausable_init();

        require(
            ISFVault(_vault).isTokenWhitelisted(address(_underlying))
                && ISFVault(_vault).isTokenWhitelisted(address(_otherToken)),
            SFUniswapV3Strategy__InvalidPoolTokens()
        );

        addressManager = _addressManager;
        vault = _vault;
        underlying = _underlying;
        otherToken = _otherToken;
        pool = IUniswapV3Pool(_pool);
        positionManager = INonfungiblePositionManager(_positionManager);
        maxTVL = _maxTVL;
        universalRouter = IUniversalRouter(_router);

        int24 spacing = IUniswapV3Pool(pool).tickSpacing();

        require(_tickLower < _tickUpper, SFUniswapV3Strategy__InvalidTicks());
        require(_tickLower % spacing == 0, SFUniswapV3Strategy__InvalidTicks());
        require(_tickUpper % spacing == 0, SFUniswapV3Strategy__InvalidTicks());

        tickLower = _tickLower;
        tickUpper = _tickUpper;

        token0 = pool.token0();
        token1 = pool.token1();

        require(
            (token0 == address(underlying) && token1 == address(_otherToken))
                || (token0 == address(_otherToken) && token1 == address(underlying)),
            SFUniswapV3Strategy__InvalidPoolTokens()
        );

        twapWindow = 1800; // 30 minutes
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    function setMaxTVL(uint256 newMaxTVL) external onlyRole(Roles.OPERATOR) {
        uint256 oldMaxTVL = maxTVL;
        maxTVL = newMaxTVL;
        emit OnMaxTVLUpdated(oldMaxTVL, newMaxTVL);
    }

    function setConfig(
        bytes calldata /*newConfig*/
    )
        external
        onlyRole(Roles.OPERATOR)
    {
        // todo: check if needed. Decode array of strategy, weights, and active status.
    }

    function setTwapWindow(uint32 newWindow) external onlyRole(Roles.OPERATOR) {
        // allow 0 (spot), otherwise require something sane
        if (newWindow != 0 && newWindow < 60) revert SFUniswapV3Strategy__InvalidTwapWindow(); // min 1 min
        uint32 old = twapWindow;
        twapWindow = newWindow;
        emit TwapWindowUpdated(old, newWindow);
    }

    /*//////////////////////////////////////////////////////////////
                               EMERGENCY
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyRole(Roles.PAUSE_GUARDIAN) {
        _pause();
    }

    function unpause() external onlyRole(Roles.PAUSE_GUARDIAN) {
        _unpause();
    }

    function emergencyExit(address receiver) external notAddressZero(receiver) onlyRole(Roles.OPERATOR) {
        _requireVaultApprovalForNFT();

        uint256 tokenId_ = positionTokenId;

        // unwind + burn NFT if exists
        if (tokenId_ != 0) {
            uint128 liquidity = PositionReader.liquidity(positionManager, tokenId_);

            if (liquidity > 0) _decreaseLiquidityAndCollect(liquidity, bytes(""));

            positionManager.burn(tokenId_);
            positionTokenId = 0;
        }

        // Transfer both tokens out so the strategy doesn't custody assets.
        uint256 balOther = otherToken.balanceOf(address(this));
        if (balOther > 0) otherToken.safeTransfer(receiver, balOther);

        uint256 balUnderlying = underlying.balanceOf(address(this));
        if (balUnderlying > 0) underlying.safeTransfer(receiver, balUnderlying);

        _pause();
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits assets into Uniswap V3 LP position.
     * @dev Expects `msg.sender` (aggregator) to have approved this contract.
     */
    function deposit(uint256 assets, bytes calldata data)
        external
        onlyContract("PROTOCOL__SF_VAULT")
        nonReentrant
        whenNotPaused
        returns (uint256 investedAssets)
    {
        require(assets > 0, SFUniswapV3Strategy__NotZeroAmount());

        // Enforce TVL cap
        require(maxTVL == 0 || totalAssets() + assets <= maxTVL, SFUniswapV3Strategy__MaxTVLReached());

        // Pull underlying from vault/aggregator
        underlying.safeTransferFrom(msg.sender, address(this), assets);

        V3ActionData memory p = _decodeV3ActionData(data);

        // 1. decide how much to swap to otherToken
        uint256 amountToSwap = (assets * p.otherRatioBPS) / MAX_BPS;
        uint256 amountUnderlyingForLP = assets - amountToSwap;

        // 2. swap with the correct payload (underlying -> otherToken)
        if (amountToSwap > 0) {
            require(p.swapToOtherData.length > 0, SFUniswapV3Strategy__InvalidStrategyData());
            _V3Swap(amountToSwap, p.swapToOtherData, true);
        }

        // 3) use actual balances to prevent swap fees makes mint revert
        uint256 desiredUnderlying = amountUnderlyingForLP;
        uint256 desiredOther = otherToken.balanceOf(address(this));

        // Sanity check ticks
        require(tickLower < tickUpper, SFUniswapV3Strategy__InvalidTicks());

        // 4) provide liquidity with slippage floors + deadline
        uint256 usedUnderlying;
        uint256 usedOther;

        if (positionTokenId == 0) {
            (usedUnderlying, usedOther) =
                _mintPosition(desiredUnderlying, desiredOther, p.pmDeadline, p.minUnderlying, p.minOther);
        } else {
            (usedUnderlying, usedOther) =
                _increaseLiquidity(desiredUnderlying, desiredOther, p.pmDeadline, p.minUnderlying, p.minOther);
        }

        investedAssets = usedUnderlying;

        _sweepToVault();
    }

    /**
     * @notice Withdraw assets from Uniswap V3 LP position.
     * @dev Tries to realize `assets` worth of underlying, may return less in edge cases.
     */
    function withdraw(uint256 assets, address receiver, bytes calldata data)
        external
        onlyContract("PROTOCOL__SF_VAULT")
        notAddressZero(receiver)
        nonReentrant
        whenNotPaused
        returns (uint256 withdrawnAssets)
    {
        require(assets > 0, SFUniswapV3Strategy__NotZeroAmount());

        uint256 total = totalAssets();
        if (total == 0) return 0;

        if (assets > total) assets = total;

        // Decode action data, same schema as in deposit
        V3ActionData memory p = _decodeV3ActionData(data);

        // 1. Compute fraction of LP to remove
        uint128 liquidityToBurn = _liquidityForValue(assets);

        if (liquidityToBurn > 0 && positionTokenId != 0) {
            _decreaseLiquidityAndCollect(liquidityToBurn, data);
        }

        // 2. swap all otherToken to underlying (if swap payload provided)
        uint256 balOther = otherToken.balanceOf(address(this));
        if (balOther > 0 && p.swapToUnderlyingData.length > 0) {
            _V3Swap(balOther, p.swapToUnderlyingData, false);
        }

        uint256 finalUnderlying = underlying.balanceOf(address(this));

        // 3. transfer underlying to receiver (aggregator), cap to requested
        withdrawnAssets = finalUnderlying > assets ? assets : finalUnderlying;
        if (withdrawnAssets > 0) underlying.safeTransfer(receiver, withdrawnAssets);

        // 4. sweep leftovers to the vault (strategy must not hold assets)
        _sweepToVault();

        return withdrawnAssets;
    }

    /*//////////////////////////////////////////////////////////////
                              MAINTENANCE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Harvests rewards from all active child strategies.
     * @param data Additional data for harvesting (not used in this implementation).
     */
    function harvest(bytes calldata data) external nonReentrant whenNotPaused onlyKeeperOrOperator {
        // Collect fees only.
        _collectFees(data);
        // Strategy must not hold assets
        _sweepToVault();

        // ? Business decision: Auto compound? This would be:
        // 1. check if strategy is approved by vault
        // 2. collect fees
        // 3. Normalize tokens to the desired ratio (50/50 by default)
        // 4. increase liquidity in the existing position.
        // 5. sweep leftovers to the vault (strategy must not hold assets)
        // 6. emit event
    }

    /**
     * @notice Rebalances the strategy by adjusting the tick range of the active position.
     * @param data Additional data for rebalancing (not used in this implementation).
     *        abi.encode(int24 newTickLower, int24 newTickUpper, uint256 pmDeadline, uint256 minUnderlying, uint256 minOther)
     */
    function rebalance(bytes calldata data) external nonReentrant whenNotPaused onlyKeeperOrOperator {
        (int24 newTickLower, int24 newTickUpper, uint256 pmDeadline, uint256 minUnderlying, uint256 minOther) =
            abi.decode(data, (int24, int24, uint256, uint256, uint256));

        require(pmDeadline >= block.timestamp, SFUniswapV3Strategy__InvalidRebalanceParams());
        require(newTickLower < newTickUpper, SFUniswapV3Strategy__InvalidRebalanceParams());

        int24 spacing = pool.tickSpacing();
        if (newTickLower % spacing != 0 || newTickUpper % spacing != 0) {
            revert SFUniswapV3Strategy__InvalidRebalanceParams();
        }

        // Any NFT ops require vault approval
        _requireVaultApprovalForNFT();

        // If there is no active position yet, just update the range and exit.
        if (positionTokenId == 0) {
            tickLower = newTickLower;
            tickUpper = newTickUpper;
            return;
        }

        // 1) Read current liquidity and fully exit the existing position.
        uint128 currentLiquidity = PositionReader.liquidity(positionManager, positionTokenId);

        // IMPORTANT: pass `data` so mins+deadline are applied on exit too
        if (currentLiquidity > 0) _decreaseLiquidityAndCollect(currentLiquidity, data);

        // 2) Burn the old NFT once all liquidity has been removed.
        uint128 remainingLiquidity = PositionReader.liquidity(positionManager, positionTokenId);
        if (remainingLiquidity == 0) {
            positionManager.burn(positionTokenId);
            positionTokenId = 0;
        }

        // 3) Update the stored tick range.
        tickLower = newTickLower;
        tickUpper = newTickUpper;

        // 4) Mint a new position using whatever balances we now hold.
        uint256 balUnderlying = underlying.balanceOf(address(this));
        uint256 balOther = otherToken.balanceOf(address(this));

        // Nothing to deploy
        if (balUnderlying == 0 && balOther == 0) return;

        _mintPosition(balUnderlying, balOther, pmDeadline, minUnderlying, minOther);

        // Ensure strategy doesn't retain assets
        _sweepToVault();
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
        uint160 sqrtPriceX96 = _valuationSqrtPriceX96();

        uint256 value = _positionValueAtSqrtPrice(sqrtPriceX96);

        uint256 idleU = underlying.balanceOf(address(this));
        if (idleU > 0) value += idleU;

        uint256 idleO = otherToken.balanceOf(address(this));
        if (idleO > 0) value += _quoteOtherAsUnderlyingAtSqrtPrice(idleO, sqrtPriceX96);

        return value;
    }

    function maxDeposit() external view returns (uint256) {
        if (maxTVL == 0) return type(uint256).max;

        uint256 current = totalAssets();
        if (current >= maxTVL) return 0;

        return maxTVL - current;
    }

    function maxWithdraw() external view returns (uint256) {
        uint256 maxUnderlying = underlying.balanceOf(address(this));

        if (positionTokenId == 0) return maxUnderlying;

        uint160 sqrtPriceX96 = _valuationSqrtPriceX96();

        // Pull liquidity + ticks + fees owed from the position
        positionManager.positions(positionTokenId);
        address t0 = PositionReader.token0(positionManager, positionTokenId);
        address t1 = PositionReader.token1(positionManager, positionTokenId);
        uint24 fee = PositionReader.fee(positionManager, positionTokenId);
        int24 tl = PositionReader.tickLower(positionManager, positionTokenId);
        int24 tu = PositionReader.tickUpper(positionManager, positionTokenId);
        uint128 liquidity = PositionReader.liquidity(positionManager, positionTokenId);
        uint128 owed0 = PositionReader.tokensOwed0(positionManager, positionTokenId);
        uint128 owed1 = PositionReader.tokensOwed1(positionManager, positionTokenId);

        // Basic sanity: this strategy should only manage pools with (underlying, otherToken)
        if (!((t0 == address(underlying) && t1 == address(otherToken))
                    || (t0 == address(otherToken) && t1 == address(underlying)))) {
            return maxUnderlying;
        }

        if (liquidity == 0) {
            // Only fees are withdrawable
            if (t0 == address(underlying)) maxUnderlying += uint256(owed0);
            else maxUnderlying += uint256(owed1);
            return maxUnderlying;
        }

        // Compute current amounts in the position (NO fees included)
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(tl), TickMath.getSqrtRatioAtTick(tu), liquidity
        );

        // Only count the underlying side (other side would require swap data)
        if (t0 == address(underlying)) {
            maxUnderlying += amt0 + uint256(owed0);
        } else {
            maxUnderlying += amt1 + uint256(owed1);
        }

        return maxUnderlying;
    }

    function getConfig() external view returns (StrategyConfig memory) {
        return StrategyConfig({
            asset: address(underlying), vault: vault, pool: address(pool), maxTVL: maxTVL, paused: paused()
        });
    }

    function positionValue() external view returns (uint256) {
        // Only the LP; excludes idle balances.
        return _positionValueAtSqrtPrice(_valuationSqrtPriceX96());
    }

    /**
     * @notice Returns the current value of the strategy's position in underlying units.
     * @return The value of the position in underlying units.
     * @dev The return bytes is encoded as
     *      abi.encode(
     *                 uint8 version => strategyType/version: 1 = UniswapV3, 2 = UniswapV4
     *                 uint256 tokenId
     *                 address pool
     *                 int24 tickLower
     *                 int24 tickUpper)
     */
    function getPositionDetails() external view returns (bytes memory) {
        // Versioned layout for cross-strategy decoding (v3=1, v4=2, ...)
        return abi.encode(uint8(1), positionTokenId, address(pool), tickLower, tickUpper);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _liquidityForValue(uint256 _value) internal view returns (uint128) {
        if (_value == 0) return 0;
        if (positionTokenId == 0) return 0;

        uint128 currentLiquidity = PositionReader.liquidity(positionManager, positionTokenId);
        if (currentLiquidity == 0) return 0;

        // USDC value of the LP position (liquidity-only valuation)
        uint256 posValue = _positionValueAtSqrtPrice(_valuationSqrtPriceX96());
        if (posValue == 0) return 0;

        // If asking for >= position value, burn all liquidity
        if (_value >= posValue) return currentLiquidity;

        // Pro-rata burn: ceil(currentLiquidity * _value / posValue)
        uint256 liq256 = FullMath.mulDivRoundingUp(uint256(currentLiquidity), _value, posValue);

        // Safety cap (should already hold true)
        if (liq256 > uint256(currentLiquidity)) liq256 = uint256(currentLiquidity);

        return uint128(liq256);
    }

    function _mintPosition(
        uint256 _amountUnderlying,
        uint256 _amountOther,
        uint256 _deadline,
        uint256 _minUnderlying,
        uint256 _minOther
    ) internal returns (uint256 usedUnderlying, uint256 usedOther) {
        // Nothing to do if both sides are zero
        require(_deadline >= block.timestamp, SFUniswapV3Strategy__InvalidDeadline());
        if (_amountUnderlying == 0 && _amountOther == 0) return (0, 0);

        // Build mint params
        INonfungiblePositionManager.MintParams memory params;
        params.token0 = token0;
        params.token1 = token1;
        params.fee = pool.fee();
        params.tickLower = tickLower;
        params.tickUpper = tickUpper;

        // Map desired amounts to correct tokens
        if (token0 == address(underlying)) {
            params.amount0Desired = _amountUnderlying;
            params.amount1Desired = _amountOther;
            params.amount0Min = _minUnderlying;
            params.amount1Min = _minOther;
        } else {
            params.amount0Desired = _amountOther;
            params.amount1Desired = _amountUnderlying;
            params.amount0Min = _minOther;
            params.amount1Min = _minUnderlying;
        }

        // The LTH of the position will be the vault
        params.recipient = vault;
        params.deadline = _deadline;

        // Approve positionManager to pull tokens
        if (params.amount0Desired > 0) {
            IERC20(params.token0).forceApprove(address(positionManager), params.amount0Desired);
        }
        if (params.amount1Desired > 0) {
            IERC20(params.token1).forceApprove(address(positionManager), params.amount1Desired);
        }

        // Mint position
        (uint256 tokenId,, uint256 amount0, uint256 amount1) = positionManager.mint(params);

        // Store the position token id on first mint
        if (positionTokenId == 0) {
            positionTokenId = tokenId;
        } else {
            // Sanity check: ensure minted tokenId matches existing positionTokenId
            require(tokenId == positionTokenId, SFUniswapV3Strategy__UnexpectedPositionTokenId());
        }

        // Map back used amounts
        if (token0 == address(underlying)) {
            usedUnderlying = amount0;
            usedOther = amount1;
        } else {
            usedUnderlying = amount1;
            usedOther = amount0;
        }
    }

    function _increaseLiquidity(
        uint256 _amountUnderlying,
        uint256 _amountOther,
        uint256 _deadline,
        uint256 _minUnderlying,
        uint256 _minOther
    ) internal returns (uint256 usedUnderlying_, uint256 usedOther_) {
        require(_deadline >= block.timestamp, SFUniswapV3Strategy__InvalidDeadline());
        _requireVaultApprovalForNFT();
        // If there is no existing position, nothing to do
        if (positionTokenId == 0) return (0, 0);
        if (_amountUnderlying == 0 && _amountOther == 0) return (0, 0);

        INonfungiblePositionManager.IncreaseLiquidityParams memory params;
        params.tokenId = positionTokenId;

        // Map desired amounts to correct tokens
        if (token0 == address(underlying)) {
            params.amount0Desired = _amountUnderlying;
            params.amount1Desired = _amountOther;
            params.amount0Min = _minUnderlying;
            params.amount1Min = _minOther;
        } else {
            params.amount0Desired = _amountOther;
            params.amount1Desired = _amountUnderlying;
            params.amount0Min = _minOther;
            params.amount1Min = _minUnderlying;
        }

        params.deadline = _deadline;

        // Approve positionManager to pull tokens
        if (params.amount0Desired > 0) {
            IERC20(token0).forceApprove(address(positionManager), params.amount0Desired);
        } else {
            IERC20(token1).forceApprove(address(positionManager), params.amount1Desired);
        }

        // Add liquidity
        (, uint256 amount0, uint256 amount1) = positionManager.increaseLiquidity(params);

        // Map back used amounts
        if (token0 == address(underlying)) {
            usedUnderlying_ = amount0;
            usedOther_ = amount1;
        } else {
            usedUnderlying_ = amount1;
            usedOther_ = amount0;
        }
    }

    /**
     * @dev Splits `_assets` (denominated in underlying units) into the part we keep as underlying
     *      and the part we intend to swap into `otherToken`.
     *      Encoding of `_data` (when non-empty): abi.encode(bytes[] inputs, uint256 deadline, uint16 otherRatioBps)
     *      - `inputs` / `deadline` are passed straight to the Universal Router.
     *      - `otherRatioBps` is a strategy-specific field (0-10000) describing what fraction of
     *        value we want to hold as `otherToken`.
     *      If `_data.length == 0` or the BPS is invalid, we default to 50/50.
     */
    function _prepareAmountsForLP(uint256 _assets, bytes calldata _data)
        internal
        pure
        returns (uint256 amountUnderlyingForLP_, uint256 amountOtherForLP_)
    {
        // TODO: refine a price-adjusted value
        // Default to 50/50 if no data
        uint16 _otherRatioBPS = MAX_BPS / 2;

        if (_data.length > 0) {
            (,, uint16 _explicitBPS) = abi.decode(_data, (bytes[], uint256, uint16));
            if (_explicitBPS <= MAX_BPS) _otherRatioBPS = _explicitBPS;
        }

        // Amount of underlying to convert to otherToken
        amountOtherForLP_ = (_assets * _otherRatioBPS) / MAX_BPS;
        amountUnderlyingForLP_ = _assets - amountOtherForLP_;
    }

    /**
     * @dev Performs a Uniswap V3 exact-in swap via Universal Router.
     * @param _amount     Amount of tokens we intend to swap.
     * @param _data       Encoded as `abi.encode(bytes[] inputs, uint256 deadline)`.
     *                    Each `inputs[i]` is the Universal Router input for a V3 swap.
     * @param _zeroForOne If true: swap `underlying -> otherToken`.
     *                    If false: swap `otherToken -> underlying`.
     *                    Not necessarily pool.token0 -> pool.token1.
     */
    function _V3Swap(uint256 _amount, bytes memory _data, bool _zeroForOne) internal {
        // Nothing to do
        if (_amount == 0) return;

        // Allow passing empty data to mean "no-op" (useful in tests or emergencyExit).
        if (_data.length == 0) return;

        // Expect data as `abi.encode(bytes[] inputs, uint256 deadline)`
        (bytes[] memory inputs, uint256 deadline) = abi.decode(_data, (bytes[], uint256));

        // Build commands: one V3_SWAP_EXACT_IN per input
        bytes memory commands = new bytes(inputs.length);
        for (uint256 i = 0; i < inputs.length; ++i) {
            commands[i] = bytes1(uint8(Commands.V3_SWAP_EXACT_IN));
        }

        // Approve the correct token depending on direction.
        if (_zeroForOne) underlying.forceApprove(address(universalRouter), _amount);
        else otherToken.forceApprove(address(universalRouter), _amount);

        // Execute the encoded v3 swaps. Path + minOut are inside `inputs`.
        universalRouter.execute(commands, inputs, deadline);
    }

    function _decreaseLiquidityAndCollect(uint128 _liquidity, bytes memory _data) internal {
        require(positionTokenId != 0, SFUniswapV3Strategy__NoPosition());

        (uint256 pmDeadline, uint256 minUnderlying, uint256 minOther) = _decodePMParams(_data);

        // Map mins according to token0/token1 ordering
        uint256 amount0Min;
        uint256 amount1Min;

        if (token0 == address(underlying)) {
            amount0Min = minUnderlying;
            amount1Min = minOther;
        } else {
            amount0Min = minOther;
            amount1Min = minUnderlying;
        }

        INonfungiblePositionManager.DecreaseLiquidityParams memory params =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: positionTokenId,
                liquidity: _liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: pmDeadline
            });

        positionManager.decreaseLiquidity(params);

        // Collect everything owed to this strategy so we can swap/sweep
        INonfungiblePositionManager.CollectParams memory cparams = INonfungiblePositionManager.CollectParams({
            tokenId: positionTokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        positionManager.collect(cparams);
    }

    function _collectFees(bytes calldata _data) internal {
        _requireVaultApprovalForNFT();
        // TODO: use data

        if (positionTokenId == 0) return;

        INonfungiblePositionManager.CollectParams memory collectParams;
        collectParams.tokenId = positionTokenId;
        collectParams.recipient = address(this);
        collectParams.amount0Max = type(uint128).max;
        collectParams.amount1Max = type(uint128).max;

        // This collects all fees and any previously decreased liquidity not yet collected.
        positionManager.collect(collectParams);
    }

    function _positionValueAtSqrtPrice(uint160 sqrtPriceX96) internal view returns (uint256) {
        if (positionTokenId == 0) return 0;

        address t0 = PositionReader.token0(positionManager, positionTokenId);
        address t1 = PositionReader.token1(positionManager, positionTokenId);
        int24 tl = PositionReader.tickLower(positionManager, positionTokenId);
        int24 tu = PositionReader.tickUpper(positionManager, positionTokenId);
        uint128 liq = PositionReader.liquidity(positionManager, positionTokenId);
        if (liq == 0) return 0;

        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(tl), TickMath.getSqrtRatioAtTick(tu), liq
        );

        uint256 v;

        if (t0 == address(underlying)) v += a0;
        else if (t0 == address(otherToken)) v += _quoteOtherAsUnderlyingAtSqrtPrice(a0, sqrtPriceX96);

        if (t1 == address(underlying)) v += a1;
        else if (t1 == address(otherToken)) v += _quoteOtherAsUnderlyingAtSqrtPrice(a1, sqrtPriceX96);

        return v;
    }

    function _quoteOtherAsUnderlyingAtSqrtPrice(uint256 amountOther, uint160 sqrtPriceX96)
        internal
        view
        returns (uint256)
    {
        if (amountOther == 0) return 0;
        if (address(underlying) == address(otherToken)) return amountOther;

        // price = token1/token0 = (sqrtPriceX96^2) / 2^192
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 q192 = 1 << 192;

        if (address(otherToken) == token0 && address(underlying) == token1) {
            // other = token0, underlying = token1 -> amountOther * price
            return FullMath.mulDiv(amountOther, priceX192, q192);
        } else if (address(otherToken) == token1 && address(underlying) == token0) {
            // other = token1, underlying = token0 -> amountOther / price
            return FullMath.mulDiv(amountOther, q192, priceX192);
        } else {
            revert SFUniswapV3Strategy__InvalidPoolTokens();
        }
    }

    // // Keep the old name for callers; now it uses TWAP/spot depending on twapWindow
    // function _quoteOtherAsUnderlying(uint256 amountOther) internal view returns (uint256) {
    //     return _quoteOtherAsUnderlyingAtSqrtPrice(amountOther, _valuationSqrtPriceX96());
    // }

    function _requireVaultApprovalForNFT() internal view {
        // vault must have approved this strategy to manage the position NFT(s)
        require(
            IERC721(address(positionManager)).isApprovedForAll(vault, address(this)),
            SFUniswapV3Strategy__VaultNotApprovedForNFT()
        );
    }

    function _decodeV3ActionData(bytes memory _data) internal view returns (V3ActionData memory p_) {
        // Defaults: 50/50, no swaps, and immediate position management deadline
        if (_data.length == 0) {
            p_.otherRatioBPS = uint16(MAX_BPS / 2);
            p_.pmDeadline = block.timestamp;
            return p_;
        }

        (p_.otherRatioBPS, p_.swapToOtherData, p_.swapToUnderlyingData, p_.pmDeadline, p_.minUnderlying, p_.minOther) =
            abi.decode(_data, (uint16, bytes, bytes, uint256, uint256, uint256));

        require(p_.otherRatioBPS <= MAX_BPS, SFUniswapV3Strategy__InvalidRebalanceParams());
        require(p_.pmDeadline >= block.timestamp, SFUniswapV3Strategy__InvalidStrategyData());
    }

    function _sweepToVault() internal {
        uint256 underlyingBalance = underlying.balanceOf(address(this));
        if (underlyingBalance > 0) underlying.safeTransfer(vault, underlyingBalance);

        uint256 otherBalance = otherToken.balanceOf(address(this));
        if (otherBalance > 0) otherToken.safeTransfer(vault, otherBalance);
    }

    function _decodePMParams(bytes memory _data)
        internal
        view
        returns (uint256 pmDeadline_, uint256 minUnderlying_, uint256 minOther_)
    {
        // defaults
        pmDeadline_ = block.timestamp;
        minUnderlying_ = 0;
        minOther_ = 0;

        if (_data.length == 0) return (pmDeadline_, minUnderlying_, minOther_);

        // Format: (int24,int24,uint256,uint256,uint256) => 5 * 32 = 160 bytes
        if (_data.length == 160) {
            (,, pmDeadline_, minUnderlying_, minOther_) = abi.decode(_data, (int24, int24, uint256, uint256, uint256));
            return (pmDeadline_, minUnderlying_, minOther_);
        }

        // Otherwise treat as V3ActionData (deposit/withdraw data schema)
        V3ActionData memory p = _decodeV3ActionData(_data);
        return (p.pmDeadline, p.minUnderlying, p.minOther);
    }

    function _valuationSqrtPriceX96() internal view returns (uint160 sqrtPriceX96_) {
        uint32 window = twapWindow;

        // Spot mode
        if (window == 0) {
            (sqrtPriceX96_,,,,,,) = pool.slot0();
            return sqrtPriceX96_;
        }

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;

        // TWAP mode, but never revert totalAssets() if observe fails
        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int56 secs = int56(uint56(window));

            int24 avgTick = int24(delta / secs);
            // round toward -infinity (Uniswap convention)
            if (delta < 0 && (delta % secs != 0)) avgTick--;

            sqrtPriceX96_ = TickMath.getSqrtRatioAtTick(avgTick);
            return sqrtPriceX96_;
        } catch {
            (sqrtPriceX96_,,,,,,) = pool.slot0();
            return sqrtPriceX96_;
        }
    }

    /// @dev required by the OZ UUPS module.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.OPERATOR) {}
}
