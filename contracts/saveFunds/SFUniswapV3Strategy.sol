// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFUniswapV3Strategy
 * @author Maikel Ordaz
 * @notice Uniswap V3 strategy implementation for SaveFunds vaults.
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ISFVault} from "contracts/interfaces/saveFunds/ISFVault.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {ISFStrategyView} from "contracts/interfaces/saveFunds/ISFStrategyView.sol";
import {ISFStrategyMaintenance} from "contracts/interfaces/saveFunds/ISFStrategyMaintenance.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "contracts/interfaces/helpers/INonfungiblePositionManager.sol";
import {IUniversalRouter} from "contracts/interfaces/helpers/IUniversalRouter.sol";
import {IUniswapV3MathHelper} from "contracts/interfaces/saveFunds/IUniswapV3MathHelper.sol";
import {IPermit2AllowanceTransfer} from "contracts/interfaces/helpers/IPermit2AllowanceTransfer.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {StrategyConfig} from "contracts/types/Strategies.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Commands} from "contracts/helpers/uniswapHelpers/libraries/Commands.sol";
import {PositionReader} from "contracts/helpers/uniswapHelpers/libraries/PositionReader.sol";

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

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint16 internal constant MAX_BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    IUniswapV3Pool public pool;
    IAddressManager internal addressManager;
    INonfungiblePositionManager internal positionManager;
    IUniversalRouter internal universalRouter;
    IUniswapV3MathHelper internal math;
    IPermit2AllowanceTransfer internal permit2;
    IERC20 internal underlying; // USDC
    IERC20 public otherToken; // USDT or any other token paired in the pool with USDC

    // Pool/vault specific
    address public vault;
    address internal token0;
    address internal token1;

    // Position parameters
    uint256 public positionTokenId; // LP NFT ID, ideally owned by vault
    uint256 internal maxTVL;
    int24 internal tickLower;
    int24 internal tickUpper;
    uint32 internal twapWindow; // seconds; 0 => spot

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
    event OnEmergencyExit(
        address indexed receiver, uint256 indexed oldTokenId, uint256 underlyingSent, uint256 otherSent
    );
    event OnTickRangeUpdated(int24 oldTickLower, int24 oldTickUpper, int24 newTickLower, int24 newTickUpper);
    event OnPositionRebalanced(
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        int24 oldTickLower,
        int24 oldTickUpper,
        int24 newTickLower,
        int24 newTickUpper
    );
    event OnLiquidityDecreased(uint256 indexed tokenId, uint128 liquidityRemoved, uint256 amount0, uint256 amount1);
    event OnSwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event OnPositionMinted(
        uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    event OnLiquidityIncreased(uint256 indexed tokenId, uint128 liquidityAdded, uint256 amount0, uint256 amount1);
    event OnPositionCollected(uint256 indexed tokenId, uint256 amount0, uint256 amount1);

    error SFUniswapV3Strategy__InvalidPoolTokens();
    error SFUniswapV3Strategy__InvalidTicks();
    error SFUniswapV3Strategy__InvalidTwapWindow();
    error SFUniswapV3Strategy__NotZeroValue();
    error SFUniswapV3Strategy__MaxTVLReached();
    error SFUniswapV3Strategy__InvalidStrategyData();
    error SFUniswapV3Strategy__InvalidRebalanceParams();
    error SFUniswapV3Strategy__VaultNotApprovedForNFT();
    error SFUniswapV3Strategy__NoPosition();
    error SFUniswapV3Strategy__InvalidDeadline();
    error SFUniswapV3Strategy__UnexpectedPositionTokenId();
    error SFUniswapV3Strategy__NotAuthorizedCaller();
    error SFUniswapV3Strategy__Permit2AmountTooLarge();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the strategy and wires up external dependencies.
     * @dev Intended to be called exactly once via proxy initialization.
     *      Validates that `_vault` whitelists `_underlying` and `_otherToken`, validates pool token ordering,
     *      and validates tick range is aligned to pool tick spacing.
     * @param _addressManager AddressManager used for role checks and named-contract authorization.
     * @param _vault Save Funds vault that owns this strategy and receives swept residual balances.
     * @param _underlying Underlying ERC20 asset accounted in the vault (e.g., USDC).
     * @param _otherToken The paired ERC20 token used for Uniswap V3 liquidity.
     * @param _pool Uniswap V3 pool for the (underlying, otherToken) pair.
     * @param _positionManager Uniswap V3 NonfungiblePositionManager used to mint/burn/manage the position NFT.
     * @param _math Math helper used for tick/price/liquidity conversions and safe mulDiv operations.
     * @param _maxTVL Maximum strategy TVL in underlying units; set to 0 for no cap.
     * @param _router Universal Router used to execute V3 swaps during deposits/withdrawals/fee collection.
     * @param _tickLower Initial lower tick for the position (must be < _tickUpper and multiple of tickSpacing).
     * @param _tickUpper Initial upper tick for the position (must be > _tickLower and multiple of tickSpacing).
     */
    function initialize(
        IAddressManager _addressManager,
        address _vault,
        IERC20 _underlying,
        IERC20 _otherToken,
        address _pool,
        address _positionManager,
        address _math,
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

        require(
            IERC20Metadata(address(_underlying)).decimals() == IERC20Metadata(address(_otherToken)).decimals(),
            SFUniswapV3Strategy__InvalidPoolTokens()
        );
        underlying = _underlying;
        otherToken = _otherToken;
        pool = IUniswapV3Pool(_pool);
        positionManager = INonfungiblePositionManager(_positionManager);
        math = IUniswapV3MathHelper(_math);
        maxTVL = _maxTVL;
        universalRouter = IUniversalRouter(_router);
        permit2 = IPermit2AllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3); // Accross all chains

        int24 spacing = IUniswapV3Pool(pool).tickSpacing();

        require(
            _tickLower < _tickUpper && _tickLower % spacing == 0 && _tickUpper % spacing == 0,
            SFUniswapV3Strategy__InvalidTicks()
        );

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

    /**
     * @notice Updates the maximum allowed TVL for this strategy (in underlying units).
     * @dev Only callable by `Roles.OPERATOR`. A value of 0 disables the cap (unlimited).
     * @param newMaxTVL New maximum TVL in underlying units (0 = unlimited).
     * @custom:invariant Deposits must revert when `maxTVL != 0` and `totalAssets() + assets > maxTVL`.
     */
    function setMaxTVL(uint256 newMaxTVL) external {
        _onlyRole(Roles.OPERATOR);
        uint256 oldMaxTVL = maxTVL;
        maxTVL = newMaxTVL;
        emit OnMaxTVLUpdated(oldMaxTVL, newMaxTVL);
    }

    /**
     * @notice Updates the TWAP window used for valuation and conversions.
     * @dev Only callable by `Roles.OPERATOR`.
     *      `newWindow == 0` enables spot pricing; otherwise requires a minimum window (sanity bound).
     * @param newWindow TWAP window in seconds (0 = spot).
     * @custom:invariant Valuation functions must use `twapWindow` as configured (spot or TWAP) without mutating state.
     */
    function setTwapWindow(uint32 newWindow) external {
        _onlyRole(Roles.OPERATOR);

        // allow 0 (spot), otherwise require something sane
        require(newWindow == 0 || newWindow >= 60, SFUniswapV3Strategy__InvalidTwapWindow()); // min 1 min
        uint32 old = twapWindow;
        twapWindow = newWindow;
        emit TwapWindowUpdated(old, newWindow);
    }

    /*//////////////////////////////////////////////////////////////
                               EMERGENCY
    //////////////////////////////////////////////////////////////*/

    function pause() external {
        _onlyRole(Roles.PAUSE_GUARDIAN);
        _pause();
    }

    function unpause() external {
        _onlyRole(Roles.PAUSE_GUARDIAN);
        _unpause();
    }

    /**
     * @notice Unwinds the active Uniswap V3 position (if any), transfers all assets out, and pauses the strategy.
     * @dev Only callable by `Roles.OPERATOR`.
     *      Requires the vault to have approved this strategy for PositionManager NFTs via `setApprovalForAll`.
     *      If a position exists, removes all liquidity, collects owed tokens, burns the NFT, then transfers both tokens.
     * @param receiver Address to receive any remaining `underlying` and `otherToken` balances after unwind.
     * @custom:invariant After completion, `positionTokenId == 0` and the strategy should not custody ERC20 balances.
     */
    function emergencyExit(address receiver) external nonReentrant {
        _onlyRole(Roles.OPERATOR);
        _notAddressZero(receiver);
        _requireVaultApprovalForNFT();

        uint256 tokenId_ = positionTokenId;

        // unwind + burn NFT if exists
        if (tokenId_ != 0) {
            uint128 liquidity = PositionReader._getUint128(positionManager, tokenId_, 7);

            if (liquidity > 0) _decreaseLiquidityAndCollect(liquidity, bytes(""));

            positionManager.burn(tokenId_);
            positionTokenId = 0;
        }

        // Transfer both tokens out so the strategy doesn't custody assets.
        uint256 balOther = otherToken.balanceOf(address(this));
        if (balOther > 0) otherToken.safeTransfer(receiver, balOther);

        uint256 balUnderlying = underlying.balanceOf(address(this));
        if (balUnderlying > 0) underlying.safeTransfer(receiver, balUnderlying);

        emit OnEmergencyExit(receiver, tokenId_, balUnderlying, balOther);

        _pause();
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pulls `assets` (underlying) from the vault and deploys it into a Uniswap V3 LP position.
     * @dev Only callable by the named vault contract ("PROTOCOL__SF_AGGREGATOR").
     *      Enforces `maxTVL` (unless 0). Optionally swaps a portion of underlying into `otherToken` via Universal Router,
     *      then mints a new position or increases liquidity on the existing one. Residual balances are swept to the vault.
     *
     *      `data` is interpreted as V3 action data and MUST be encoded as:
     *      `abi.encode(uint16 otherRatioBPS, bytes swapToOtherData, bytes swapToUnderlyingData, uint256 pmDeadline, uint256 minUnderlying, uint256 minOther)`
     *      where `swapToOtherData` / `swapToUnderlyingData` are each encoded as:
     *      `abi.encode(bytes[] inputs, uint256 deadline)` (passed to Universal Router `execute`).
     *
     *      If `data.length == 0`, defaults are used: 50/50 ratio, no swaps, `pmDeadline = block.timestamp`, mins = 0.
     * @param assets Amount of `underlying` to deposit.
     * @param data ABI-encoded V3 action data (see @dev for exact encoding).
     * @return investedAssets Amount of `underlying` effectively deployed into LP (usedUnderlying side).
     * @custom:invariant External entrypoints must not retain idle `underlying` balances; leftovers are swept to `vault`.
     *                  `otherToken` may remain in the strategy and is accounted for in `totalAssets()`.
     */
    function deposit(uint256 assets, bytes calldata data)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 investedAssets)
    {
        _onlyContract("PROTOCOL__SF_AGGREGATOR");
        require(assets > 0, SFUniswapV3Strategy__NotZeroValue());

        // Enforce TVL cap
        require(maxTVL == 0 || totalAssets() + assets <= maxTVL, SFUniswapV3Strategy__MaxTVLReached());

        // Pull underlying from vault/aggregator
        underlying.safeTransferFrom(msg.sender, address(this), assets);

        V3ActionData memory p = _decodeV3ActionData(data);

        // 1. decide how much to swap to otherToken
        uint256 amountToSwap = (assets * p.otherRatioBPS) / MAX_BPS;
        uint256 amountUnderlyingForLP = assets - amountToSwap;

        // 2. swap with the correct payload (underlying -> otherToken)
        if (amountToSwap > 0) _V3Swap(amountToSwap, p.swapToOtherData, true);

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
     * @notice Withdraws up to `assets` (in underlying units) by removing liquidity and returning underlying to `receiver`.
     * @dev Only callable by the named vault contract ("PROTOCOL__SF_AGGREGATOR").
     *      Computes the pro-rata liquidity to burn for the requested value, decreases liquidity, collects owed tokens,
     *      optionally swaps any collected/idle `otherToken` into `underlying` (if swap payload provided), then transfers
     *      up to `assets` underlying to `receiver` and sweeps leftovers back to the vault.
     *
     *      `data` uses the same V3 action encoding as `deposit`:
     *      `abi.encode(uint16 otherRatioBPS, bytes swapToOtherData, bytes swapToUnderlyingData, uint256 pmDeadline, uint256 minUnderlying, uint256 minOther)`
     *      where `swapToUnderlyingData` is used to swap `otherToken -> underlying` via Universal Router.
     * @param assets Requested amount of `underlying` to withdraw (will be capped to `totalAssets()`).
     * @param receiver Address receiving the withdrawn underlying.
     * @param data ABI-encoded V3 action data (see @dev for exact encoding).
     * @return withdrawnAssets Actual underlying transferred to `receiver` (capped to requested `assets`).
     * @custom:invariant External entrypoints must not retain `underlying`/`otherToken` balances; leftovers are swept to `vault`.
     */
    function withdraw(uint256 assets, address receiver, bytes calldata data)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 withdrawnAssets)
    {
        _onlyContract("PROTOCOL__SF_AGGREGATOR");
        _notAddressZero(receiver);
        require(assets > 0, SFUniswapV3Strategy__NotZeroValue());

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
     * @notice Collects accrued Uniswap V3 fees and sweeps proceeds to the vault.
     * @dev Only callable by an address with `Roles.KEEPER` or `Roles.OPERATOR`.
     *      Collects all fees owed to the position, optionally swaps `otherToken -> underlying` if swap payload provided,
     *      then sweeps any residual balances to the vault.
     *
     *      `data` uses the same V3 action encoding as `deposit`/`withdraw`:
     *      `abi.encode(uint16 otherRatioBPS, bytes swapToOtherData, bytes swapToUnderlyingData, uint256 pmDeadline, uint256 minUnderlying, uint256 minOther)`
     *      where `swapToUnderlyingData` is used for the optional swap before sweeping.
     * @param data ABI-encoded V3 action data (see @dev for exact encoding).
     * @custom:invariant After completion, the strategy should not custody idle `underlying`; any `underlying` proceeds are swept to `vault`.
     *                  `otherToken` may remain in the strategy and is accounted for in `totalAssets()`.
     */
    function harvest(bytes calldata data) external nonReentrant whenNotPaused {
        _onlyContract("PROTOCOL__SF_AGGREGATOR");
        // Collect fees only.
        _collectFees(data);

        // ? Business decision: Auto compound? This would be:
        // 1. check if strategy is approved by vault
        // 2. collect fees
        // 3. Normalize tokens to the desired ratio (50/50 by default)
        // 4. increase liquidity in the existing position.
        // 5. sweep leftovers to the vault (strategy must not hold assets)
        // 6. emit event
    }

    /**
     * @notice Rebalances the strategy by changing the tick range and redeploying liquidity into a new position.
     * @dev Only callable by an address with `Roles.KEEPER` or `Roles.OPERATOR`.
     *      Requires the vault to have approved this strategy for PositionManager NFTs via `setApprovalForAll`.
     *      If a position exists, fully exits and burns the old NFT, updates ticks, and mints a new position with current balances.
     *      Any residual balances are swept to the vault.
     *
     *      `data` MUST be encoded as:
     *      `abi.encode(int24 newTickLower, int24 newTickUpper, uint256 pmDeadline, uint256 minUnderlying, uint256 minOther)`
     *      where mins + deadline apply to both the exit (decrease) and the new mint.
     * @param data ABI-encoded rebalance params (see @dev for exact encoding).
     * @custom:invariant `tickLower` and `tickUpper` must remain aligned to pool tickSpacing; ERC20 leftovers are swept to `vault`.
     */
    function rebalance(bytes calldata data) external nonReentrant whenNotPaused {
        _onlyContract("PROTOCOL__SF_AGGREGATOR");
        uint256 oldTokenId = positionTokenId;
        int24 oldTickLower = tickLower;
        int24 oldTickUpper = tickUpper;

        (int24 newTickLower, int24 newTickUpper, uint256 pmDeadline, uint256 minUnderlying, uint256 minOther) =
            abi.decode(data, (int24, int24, uint256, uint256, uint256));

        require(pmDeadline >= block.timestamp, SFUniswapV3Strategy__InvalidRebalanceParams());
        require(newTickLower < newTickUpper, SFUniswapV3Strategy__InvalidRebalanceParams());

        int24 spacing = pool.tickSpacing();
        require(
            newTickLower % spacing == 0 && newTickUpper % spacing == 0, SFUniswapV3Strategy__InvalidRebalanceParams()
        );

        // Any NFT ops require vault approval
        _requireVaultApprovalForNFT();

        // If there is no active position yet, just update the range and exit.
        if (positionTokenId == 0) {
            tickLower = newTickLower;
            tickUpper = newTickUpper;
            return;
        }

        // 1) Read current liquidity and fully exit the existing position.
        uint128 currentLiquidity = PositionReader._getUint128(positionManager, positionTokenId, 7);

        // IMPORTANT: pass `data` so mins+deadline are applied on exit too
        if (currentLiquidity > 0) _decreaseLiquidityAndCollect(currentLiquidity, data);

        // 2) Burn the old NFT once all liquidity has been removed.
        positionManager.burn(positionTokenId);
        positionTokenId = 0;

        // 3) Update the stored tick range.
        tickLower = newTickLower;
        tickUpper = newTickUpper;

        emit OnTickRangeUpdated(oldTickLower, oldTickUpper, newTickLower, newTickUpper);

        // 4) Mint a new position using whatever balances we now hold.
        uint256 balUnderlying = underlying.balanceOf(address(this));
        uint256 balOther = otherToken.balanceOf(address(this));

        // Nothing to deploy
        if (balUnderlying == 0 && balOther == 0) return;

        _mintPosition(balUnderlying, balOther, pmDeadline, minUnderlying, minOther);

        emit OnPositionRebalanced(oldTokenId, positionTokenId, oldTickLower, oldTickUpper, newTickLower, newTickUpper);

        // Ensure strategy doesn't retain assets
        _sweepToVault();
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the underlying ERC20 asset address accounted by the vault for this strategy.
     * @dev Pure view helper used by the aggregator/vault integration.
     * @return asset_ Address of the underlying ERC20 token.
     * @custom:invariant View function must not mutate state.
     */
    function asset() external view returns (address) {
        return address(underlying);
    }

    /**
     * @notice Returns the maximum additional `underlying` amount this strategy can accept right now.
     * @dev If `maxTVL == 0`, returns `type(uint256).max`. Otherwise returns remaining capacity until hitting `maxTVL`.
     * @return maxAssets Maximum depositable underlying amount at current state.
     * @custom:invariant View function must not mutate state.
     */
    function maxDeposit() external view returns (uint256) {
        if (maxTVL == 0) return type(uint256).max;

        uint256 current = totalAssets();
        if (current >= maxTVL) return 0;

        return maxTVL - current;
    }

    /**
     * @notice Returns the maximum withdrawable amount in underlying units at current state and price.
     * @dev Includes idle underlying held by the strategy plus the underlying-equivalent value of the LP position and owed fees.
     *      Does not attempt to value any idle `otherToken` balance (which should normally be swept to the vault).
     * @return maxAssets Maximum withdrawable underlying amount.
     * @custom:invariant View function must not mutate state.
     */
    function maxWithdraw() external view returns (uint256) {
        uint256 maxUnderlying = underlying.balanceOf(address(this));

        if (positionTokenId == 0) return maxUnderlying;

        uint160 sqrtPriceX96 = _valuationSqrtPriceX96();

        // Pull liquidity + ticks + fees owed from the position
        address t0 = PositionReader._getAddress(positionManager, positionTokenId, 2);
        address t1 = PositionReader._getAddress(positionManager, positionTokenId, 3);
        int24 tl = PositionReader._getInt24(positionManager, positionTokenId, 5);
        int24 tu = PositionReader._getInt24(positionManager, positionTokenId, 6);
        uint128 liquidity = PositionReader._getUint128(positionManager, positionTokenId, 7);
        uint128 owed0 = PositionReader._getUint128(positionManager, positionTokenId, 10);
        uint128 owed1 = PositionReader._getUint128(positionManager, positionTokenId, 11);

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
        (uint256 amt0, uint256 amt1) = math.getAmountsForLiquidity(
            sqrtPriceX96, math.getSqrtRatioAtTick(tl), math.getSqrtRatioAtTick(tu), liquidity
        );

        // Only count the underlying side (other side would require swap data)
        if (t0 == address(underlying)) {
            maxUnderlying += amt0 + uint256(owed0);
        } else {
            maxUnderlying += amt1 + uint256(owed1);
        }

        return maxUnderlying;
    }

    /**
     * @notice Returns the current strategy configuration for offchain/indexer usage.
     * @dev Packs core fields into a `StrategyConfig` struct.
     * @return config Strategy configuration snapshot.
     * @custom:invariant View function must not mutate state.
     */
    function getConfig() external view returns (StrategyConfig memory) {
        return StrategyConfig({asset: address(underlying), vault: vault, pool: address(pool), paused: paused()});
    }

    /**
     * @notice Returns the value of the active LP position in underlying units, excluding idle balances.
     * @dev Uses spot/TWAP pricing depending on `twapWindow` and values liquidity only (fees excluded).
     * @return valueUnderlying Value of the LP position denominated in underlying units.
     * @custom:invariant View function must not mutate state.
     */
    function positionValue() external view returns (uint256) {
        // Only the LP; excludes idle balances.
        return _positionValueAtSqrtPrice(_valuationSqrtPriceX96());
    }

    /**
     * @notice Returns a compact, versioned encoding of the current Uniswap V3 position metadata.
     * @dev Encoded as: `abi.encode(uint8 version, uint256 tokenId, address pool, int24 tickLower, int24 tickUpper)`.
     *      `version` is intended for cross-strategy decoding (e.g., 1 = Uniswap V3).
     * @return positionDetails ABI-encoded position metadata blob.
     * @custom:invariant View function must not mutate state.
     */
    function getPositionDetails() external view returns (bytes memory) {
        // Versioned layout for cross-strategy decoding (v3=1, v4=2, ...)
        return abi.encode(uint8(1), positionTokenId, address(pool), tickLower, tickUpper);
    }

    /**
     * @notice Returns the total strategy value in underlying units (LP position + idle balances).
     * @dev Uses spot/TWAP pricing depending on `twapWindow`. Includes:
     *      (1) liquidity-only valuation of the LP position,
     *      (2) idle underlying balance, and
     *      (3) idle otherToken converted into underlying at the same price.
     * @return total Value in underlying units.
     * @custom:invariant View function must not mutate state.
     */
    function totalAssets() public view returns (uint256) {
        uint160 sqrtPriceX96 = _valuationSqrtPriceX96();

        uint256 value = _positionValueAtSqrtPrice(sqrtPriceX96);

        uint256 idleU = underlying.balanceOf(address(this));
        if (idleU > 0) value += idleU;

        uint256 idleO = otherToken.balanceOf(address(this));
        if (idleO > 0) value += _quoteOtherAsUnderlyingAtSqrtPrice(idleO, sqrtPriceX96);

        return value;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Ensures the vault has approved this strategy to manage PositionManager NFTs via `setApprovalForAll`.
     * @custom:invariant Any function that mints/burns/decreases/increases the position must require this approval.
     */
    function _requireVaultApprovalForNFT() internal view {
        // ? Business decision: would be easier if the strategy owned the NFT directly, instead of the vault. Although this approach is nicer to migrate positions between strategies.
        // vault must have approved this strategy to manage the position NFT(s)
        require(
            IERC721(address(positionManager)).isApprovedForAll(vault, address(this)),
            SFUniswapV3Strategy__VaultNotApprovedForNFT()
        );
    }

    /**
     * @dev Decreases liquidity for the active position and collects all owed tokens to this strategy.
     *      Slippage mins + deadline are decoded via `_decodePMParams(_data)`.
     * @param _liquidity Amount of liquidity to remove.
     * @param _data ABI-encoded params. Accepted encodings:
     *      - empty bytes: defaults (`deadline=block.timestamp`, mins = 0),
     *      - rebalance params: `abi.encode(int24,int24,uint256 pmDeadline,uint256 minUnderlying,uint256 minOther)` (160 bytes),
     *      - V3 action data: `abi.encode(uint16,bytes,bytes,uint256 pmDeadline,uint256 minUnderlying,uint256 minOther)`.
     * @custom:invariant Must only operate when `positionTokenId != 0` and must not change `positionTokenId`.
     */
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

        (uint256 amount0, uint256 amount1) = positionManager.decreaseLiquidity(params);
        emit OnLiquidityDecreased(positionTokenId, _liquidity, amount0, amount1);

        // Collect everything owed to this strategy so we can swap/sweep
        INonfungiblePositionManager.CollectParams memory cparams = INonfungiblePositionManager.CollectParams({
            tokenId: positionTokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (uint256 c0, uint256 c1) = positionManager.collect(cparams);
        emit OnPositionCollected(positionTokenId, c0, c1);
    }

    /**
     * @dev Decodes the strategy action bundle used for deposit/withdraw/harvest/fee collection.
     *      Expected encoding:
     *      `abi.encode(uint16 otherRatioBPS, bytes swapToOtherData, bytes swapToUnderlyingData, uint256 pmDeadline, uint256 minUnderlying, uint256 minOther)`.
     *      If `_data.length == 0`, defaults are used (50/50 ratio, no swaps, `pmDeadline = block.timestamp`, mins = 0).
     * @param _data ABI-encoded action data.
     * @return p_ Decoded `V3ActionData` struct.
     * @custom:invariant `otherRatioBPS` must be `<= MAX_BPS` and `pmDeadline >= block.timestamp` when provided.
     */
    function _decodeV3ActionData(bytes memory _data) internal view returns (V3ActionData memory p_) {
        // Defaults: no swap (0% to otherToken), and immediate position management deadline.
        // Payloads in `data` MUST be provided to swap.
        if (_data.length == 0) {
            p_.otherRatioBPS = 0;
            p_.pmDeadline = block.timestamp;
            return p_;
        }

        (p_.otherRatioBPS, p_.swapToOtherData, p_.swapToUnderlyingData, p_.pmDeadline, p_.minUnderlying, p_.minOther) =
            abi.decode(_data, (uint16, bytes, bytes, uint256, uint256, uint256));

        require(p_.otherRatioBPS <= MAX_BPS, SFUniswapV3Strategy__InvalidRebalanceParams());
        require(p_.pmDeadline >= block.timestamp, SFUniswapV3Strategy__InvalidStrategyData());

        // If caller requests swapping some of the deposit into otherToken, they must provide swap calldata.
        if (p_.otherRatioBPS > 0) require(p_.swapToOtherData.length > 0, SFUniswapV3Strategy__InvalidStrategyData());
    }

    /**
     * @dev Performs a Uniswap V3 exact-in swap through Universal Router.
     *      `_data` MUST be encoded as `abi.encode(bytes[] inputs, uint256 deadline)` where each `inputs[i]` is the
     *      Universal Router input for a `Commands.V3_SWAP_EXACT_IN` action. Commands are constructed internally.
     *      Passing empty `_data` is treated as a no-op (useful for tests/emergency paths).
     * @param _amount Amount of tokens intended to be swapped.
     * @param _data ABI-encoded Universal Router inputs + deadline: `abi.encode(bytes[] inputs, uint256 deadline)`.
     * @param _zeroForOne If true, swaps `underlying -> otherToken`; otherwise swaps `otherToken -> underlying`.
     * @custom:invariant Swap execution must not leave residual allowances or balances unaccounted; leftovers are swept by callers.
     */
    function _V3Swap(uint256 _amount, bytes memory _data, bool _zeroForOne) internal {
        // Nothing to do
        if (_amount == 0) return;
        if (_data.length == 0) return;

        //  Expect data as `abi.encode(bytes[] inputs, uint256 deadline)`
        (bytes[] memory inputs, uint256 deadline) = abi.decode(_data, (bytes[], uint256));
        require(inputs.length > 0, SFUniswapV3Strategy__InvalidStrategyData());
        require(deadline >= block.timestamp, SFUniswapV3Strategy__InvalidDeadline());

        bytes memory commands = new bytes(inputs.length);
        IERC20 tokenIn = _zeroForOne ? underlying : otherToken;
        address expectedIn = address(tokenIn);
        address expectedOut = _zeroForOne ? address(otherToken) : address(underlying);

        uint256 totalIn;

        for (uint256 i; i < inputs.length; ++i) {
            commands[i] = bytes1(uint8(Commands.V3_SWAP_EXACT_IN));

            // (recipient, amountIn, amountOutMin, path, payerIsUser)
            (address recipient, uint256 amountIn,, bytes memory path, bool payerIsUser) =
                abi.decode(inputs[i], (address, uint256, uint256, bytes, bool));

            // Safety checks
            require(recipient == address(this), SFUniswapV3Strategy__InvalidStrategyData());
            require(payerIsUser, SFUniswapV3Strategy__InvalidStrategyData());

            _validateSingleHopPath(path, expectedIn, expectedOut);

            totalIn += amountIn;
        }

        // Allow dust / unexpected extra balance in the contract
        // We only require that swap inputs sum to `_amount`.
        require(totalIn <= _amount, SFUniswapV3Strategy__InvalidStrategyData());

        // Enforce we actually have enough `tokenIn` to cover swap payload
        require(tokenIn.balanceOf(address(this)) >= totalIn, SFUniswapV3Strategy__InvalidStrategyData());

        uint256 amountToSwap = totalIn;

        // Make UniversalRouter swaps work, as it pays via Permit2
        _ensurePermit2Max(tokenIn);

        // Not strictly needed for Permit2, but doesn't hurt
        tokenIn.forceApprove(address(universalRouter), amountToSwap);

        uint256 outBefore = IERC20(expectedOut).balanceOf(address(this));

        universalRouter.execute(commands, inputs, deadline);

        uint256 outAfter = IERC20(expectedOut).balanceOf(address(this));

        emit OnSwapExecuted(address(tokenIn), expectedOut, amountToSwap, outAfter - outBefore);

        // Clear allowance
        tokenIn.forceApprove(address(universalRouter), 0);
    }

    /**
     * @dev Mints the Uniswap V3 position using the provided token amounts and slippage bounds.
     * @param _amountUnderlying Desired underlying amount to supply.
     * @param _amountOther Desired otherToken amount to supply.
     * @param _deadline PositionManager deadline (must be >= block.timestamp).
     * @param _minUnderlying Minimum underlying amount to add (slippage floor).
     * @param _minOther Minimum otherToken amount to add (slippage floor).
     * @return usedUnderlying Actual underlying amount consumed by the mint.
     * @return usedOther Actual otherToken amount consumed by the mint.
     */
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
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = positionManager.mint(params);

        // reset approvals
        if (params.amount0Desired > 0) IERC20(params.token0).forceApprove(address(positionManager), 0);
        if (params.amount1Desired > 0) IERC20(params.token1).forceApprove(address(positionManager), 0);

        emit OnPositionMinted(tokenId, tickLower, tickUpper, liquidity, amount0, amount1);

        // Store the position token id on first mint
        require(positionTokenId == 0, SFUniswapV3Strategy__UnexpectedPositionTokenId());
        positionTokenId = tokenId;

        // Map back used amounts
        if (token0 == address(underlying)) {
            usedUnderlying = amount0;
            usedOther = amount1;
        } else {
            usedUnderlying = amount1;
            usedOther = amount0;
        }
    }

    /**
     * @dev Increases liquidity on the existing position using the provided token amounts and slippage bounds.
     *      Requires vault approval for NFT management and an existing `positionTokenId`.
     * @param _amountUnderlying Desired underlying amount to supply.
     * @param _amountOther Desired otherToken amount to supply.
     * @param _deadline PositionManager deadline (must be >= block.timestamp).
     * @param _minUnderlying Minimum underlying amount to add (slippage floor).
     * @param _minOther Minimum otherToken amount to add (slippage floor).
     * @return usedUnderlying_ Actual underlying amount consumed.
     * @return usedOther_ Actual otherToken amount consumed.
     * @custom:invariant Must not modify `positionTokenId` and must only act when `positionTokenId != 0`.
     */
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

        // Approve positionManager to pull both tokens.
        if (params.amount0Desired > 0) {
            IERC20(token0).forceApprove(address(positionManager), params.amount0Desired);
        }
        if (params.amount1Desired > 0) {
            IERC20(token1).forceApprove(address(positionManager), params.amount1Desired);
        }

        // Add liquidity
        (uint128 liq, uint256 amount0, uint256 amount1) = positionManager.increaseLiquidity(params);
        emit OnLiquidityIncreased(positionTokenId, liq, amount0, amount1);

        //  Clear approvals after use
        if (params.amount0Desired > 0) IERC20(token0).forceApprove(address(positionManager), 0);
        if (params.amount1Desired > 0) IERC20(token1).forceApprove(address(positionManager), 0);

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
     * @dev Transfers any residual `underlying` balance to the vault.
     *      IMPORTANT: `otherToken` is intentionally retained in the strategy (it is valued inside `totalAssets()`),
     *      and should be swapped to `underlying` when needed (e.g. on withdraw/harvest when swap payload is provided).
     * @custom:invariant After state-changing external entrypoints, this sweep should leave `underlying` balance at zero (best-effort).
     */
    function _sweepToVault() internal {
        uint256 underlyingBalance = underlying.balanceOf(address(this));
        if (underlyingBalance > 0) underlying.safeTransfer(vault, underlyingBalance);
    }

    /**
     * @dev Computes the amount of liquidity to remove (rounded up) to target `_value` underlying units from the LP position.
     * @param _value Desired value in underlying units.
     * @return liquidityToBurn Amount of liquidity to burn (0 if no position/value).
     * @custom:invariant Returned liquidity must be `<= currentLiquidity` and is `currentLiquidity` when `_value >= position value`.
     */
    function _liquidityForValue(uint256 _value) internal view returns (uint128) {
        if (_value == 0) return 0;
        if (positionTokenId == 0) return 0;

        uint128 currentLiquidity = PositionReader._getUint128(positionManager, positionTokenId, 7);
        if (currentLiquidity == 0) return 0;

        // USDC value of the LP position (liquidity-only valuation)
        uint256 posValue = _positionValueAtSqrtPrice(_valuationSqrtPriceX96());
        if (posValue == 0) return 0;

        // If asking for >= position value, burn all liquidity
        if (_value >= posValue) return currentLiquidity;

        // Pro-rata burn: ceil(currentLiquidity * _value / posValue)
        uint256 liq256 = math.mulDivRoundingUp(uint256(currentLiquidity), _value, posValue);

        // Safety cap (should already hold true)
        if (liq256 > uint256(currentLiquidity)) liq256 = uint256(currentLiquidity);

        return uint128(liq256);
    }

    /**
     * @dev Collects all accrued fees from the active position and optionally swaps `otherToken -> underlying` before sweeping.
     *      Requires vault approval for NFT management.
     *
     *      `data` uses the same V3 action encoding as `deposit`/`withdraw`:
     *      `abi.encode(uint16, bytes swapToOtherData, bytes swapToUnderlyingData, uint256 pmDeadline, uint256 minUnderlying, uint256 minOther)`
     *      where only `swapToUnderlyingData` is relevant here for the optional swap.
     * @param data ABI-encoded V3 action data (see @dev for exact encoding).
     * @custom:invariant Must not retain ERC20 balances; any proceeds are swept to `vault`.
     */
    function _collectFees(bytes calldata data) internal {
        _requireVaultApprovalForNFT();

        if (positionTokenId == 0) return;

        // Standard decode
        V3ActionData memory p = _decodeV3ActionData(data);

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: positionTokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        // Collect all fees (and any owed tokens)
        (uint256 a0, uint256 a1) = positionManager.collect(collectParams);
        emit OnPositionCollected(positionTokenId, a0, a1);

        // Optional: swap collected otherToken -> underlying if keeper supplied swap payload
        uint256 balOther = otherToken.balanceOf(address(this));
        if (balOther > 0 && p.swapToUnderlyingData.length > 0) {
            _V3Swap(balOther, p.swapToUnderlyingData, false);
        }

        // Never retain assets in the strategy
        _sweepToVault();
    }

    /**
     * @dev Returns the sqrt price used for valuation (spot or TWAP depending on `twapWindow`).
     *      In TWAP mode, attempts `pool.observe` and falls back to spot price if observe fails.
     * @return sqrtPriceX96_ Sqrt price Q64.96 used for valuation.
     * @custom:invariant View helper must not mutate state and must return a price consistent with `twapWindow` mode.
     */
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

            sqrtPriceX96_ = math.getSqrtRatioAtTick(avgTick);
            return sqrtPriceX96_;
        } catch {
            (sqrtPriceX96_,,,,,,) = pool.slot0();
            return sqrtPriceX96_;
        }
    }

    /**
     * @dev Values only the LP position (liquidity) at a given sqrt price, denominated in underlying units.
     *      Fees are not included in this valuation.
     * @param sqrtPriceX96 Sqrt price Q64.96 to use for conversion.
     * @return valueUnderlying Liquidity-only value in underlying units.
     * @custom:invariant Returns 0 when `positionTokenId == 0` or liquidity is 0; view helper must not mutate state.
     */
    function _positionValueAtSqrtPrice(uint160 sqrtPriceX96) internal view returns (uint256) {
        if (positionTokenId == 0) return 0;

        address t0 = PositionReader._getAddress(positionManager, positionTokenId, 2);
        address t1 = PositionReader._getAddress(positionManager, positionTokenId, 3);
        int24 tl = PositionReader._getInt24(positionManager, positionTokenId, 5);
        int24 tu = PositionReader._getInt24(positionManager, positionTokenId, 6);
        uint128 liq = PositionReader._getUint128(positionManager, positionTokenId, 7);
        if (liq == 0) return 0;

        (uint256 a0, uint256 a1) =
            math.getAmountsForLiquidity(sqrtPriceX96, math.getSqrtRatioAtTick(tl), math.getSqrtRatioAtTick(tu), liq);

        uint256 v;

        if (t0 == address(underlying)) v += a0;
        else if (t0 == address(otherToken)) v += _quoteOtherAsUnderlyingAtSqrtPrice(a0, sqrtPriceX96);

        if (t1 == address(underlying)) v += a1;
        else if (t1 == address(otherToken)) v += _quoteOtherAsUnderlyingAtSqrtPrice(a1, sqrtPriceX96);

        return v;
    }

    /**
     * @dev Converts an `otherToken` amount into underlying units using the given sqrt price.
     *      Assumes the pool tokens are exactly (underlying, otherToken) in either ordering.
     * @param amountOther Amount of `otherToken` to convert.
     * @param sqrtPriceX96 Sqrt price Q64.96 used for conversion.
     * @return amountUnderlying Underlying-equivalent amount at the given price.
     * @custom:invariant Must revert if pool tokens are inconsistent with configured `underlying`/`otherToken`.
     */
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
            return math.mulDiv(amountOther, priceX192, q192);
        } else if (address(otherToken) == token1 && address(underlying) == token0) {
            // other = token1, underlying = token0 -> amountOther / price
            return math.mulDiv(amountOther, q192, priceX192);
        } else {
            revert SFUniswapV3Strategy__InvalidPoolTokens();
        }
    }

    /**
     * @dev Extracts PositionManager min amounts and deadline from flexible input encodings.
     *      Accepted formats:
     *      - empty bytes: defaults (`deadline=block.timestamp`, mins = 0),
     *      - rebalance params: `abi.encode(int24,int24,uint256 pmDeadline,uint256 minUnderlying,uint256 minOther)` (160 bytes),
     *      - V3 action data: `abi.encode(uint16,bytes,bytes,uint256 pmDeadline,uint256 minUnderlying,uint256 minOther)`.
     * @param _data ABI-encoded parameter blob.
     * @return pmDeadline_ Deadline for PositionManager operations.
     * @return minUnderlying_ Slippage floor for the underlying side.
     * @return minOther_ Slippage floor for the otherToken side.
     * @custom:invariant Returns sane defaults when `_data` is empty and must not mutate state.
     */
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

    function _ensurePermit2Max(IERC20 _tokenIn) internal {
        // ERC20 allowance -> Permit2
        uint256 a = _tokenIn.allowance(address(this), address(permit2));
        if (a != type(uint256).max) _tokenIn.forceApprove(address(permit2), type(uint256).max);

        // Permit2 allowance -> UniversalRouter
        (uint160 allowed, uint48 expiration,) =
            permit2.allowance(address(this), address(_tokenIn), address(universalRouter));

        if (allowed != type(uint160).max || expiration != type(uint48).max) {
            permit2.approve(address(_tokenIn), address(universalRouter), type(uint160).max, type(uint48).max);
        }
    }

    function _firstToken(bytes memory _path) internal pure returns (address token_) {
        require(_path.length >= 20, SFUniswapV3Strategy__InvalidStrategyData());
        assembly {
            token_ := shr(96, mload(add(_path, 32)))
        }
    }

    function _firstFee(bytes memory _path) internal pure returns (uint24 fee_) {
        require(_path.length >= 23, SFUniswapV3Strategy__InvalidStrategyData());
        assembly {
            fee_ := shr(232, mload(add(_path, 52))) // 32 + 20 = 52
        }
    }

    function _lastToken(bytes memory _path) internal pure returns (address token_) {
        require(_path.length >= 20, SFUniswapV3Strategy__InvalidStrategyData());
        uint256 start = 32 + _path.length - 20;
        assembly {
            token_ := shr(96, mload(add(_path, start)))
        }
    }

    function _validateSingleHopPath(bytes memory _path, address _expectedIn, address _expectedOut) internal view {
        // Uniswap V3 single-hop path: tokenIn(20) + fee(3) + tokenOut(20) = 43 bytes
        require(_path.length == 43, SFUniswapV3Strategy__InvalidStrategyData());

        require(
            _firstToken(_path) == _expectedIn && _lastToken(_path) == _expectedOut,
            SFUniswapV3Strategy__InvalidStrategyData()
        );

        uint24 fee = _firstFee(_path);
        require(fee == pool.fee(), SFUniswapV3Strategy__InvalidStrategyData());
    }

    function _notAddressZero(address _addr) internal pure {
        require(_addr != address(0), SFUniswapV3Strategy__NotZeroValue());
    }

    function _onlyContract(string memory _name) internal view {
        require(addressManager.hasName(_name, msg.sender), SFUniswapV3Strategy__NotAuthorizedCaller());
    }

    function _onlyRole(bytes32 _role) internal view {
        require(addressManager.hasRole(_role, msg.sender), SFUniswapV3Strategy__NotAuthorizedCaller());
    }

    /// @dev required by the OZ UUPS module.
    function _authorizeUpgrade(address newImplementation) internal view override {
        _onlyRole(Roles.OPERATOR);
    }
}
