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

    uint256 public maxTVL;
    uint256 public positionTokenId; // LP NFT ID, ideally owned by vault
    int24 public tickLower;
    int24 public tickUpper;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnMaxTVLUpdated(uint256 oldMaxTVL, uint256 newMaxTVL);

    error SFUniswapV3Strategy__NotAuthorizedCaller();
    error SFUniswapV3Strategy__NotAddressZero();
    error SFUniswapV3Strategy__NotZeroAmount();
    error SFUniswapV3Strategy__MaxTVLReached();
    error SFUniswapV3Strategy__InvalidPoolTokens();
    error SFUniswapV3Strategy__UnexpectedPositionTokenId();
    error SFUniswapV3Strategy__InvalidRebalanceParams();
    error SFUniswapV3Strategy__InvalidTicks();

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
        // withdraw all
        // TODO: maybe burn the nft? The problem is that the owner is the vault
        if (positionTokenId != 0) _decreaseLiquidityAndCollect(type(uint128).max, bytes(""));

        // swap all otherToken to underlying
        uint256 balOther = otherToken.balanceOf(address(this));
        if (balOther > 0) _V3Swap(balOther, bytes(""), false);

        // send everything out
        uint256 balanceUnderlying = underlying.balanceOf(address(this));
        if (balanceUnderlying > 0) underlying.safeTransfer(receiver, balanceUnderlying);

        _pause();
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits assets into Uniswap V3 LP position.
     * @dev Expects `msg.sender` (aggregator) to have approved this contract.
     * TODO: maybe use permit2
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

        // TODO: interpret data for slippage, ratios, amounts, etc. for now 50/50 assumption in dollars

        // 1. decide how much to swap to otherToken
        (uint256 amountUnderlyingForLP, uint256 amountOtherForLP) = _prepareAmountsForLP(assets, data);

        // 2. ensure holds the right tokens balances
        if (amountOtherForLP > 0) _V3Swap(amountOtherForLP, data, true);

        // 3. provide liquidity via positionManager.mint/increaseLiquidity
        uint256 usedUnderlying;
        uint256 usedOther;

        // Sanity check ticks
        require(tickLower < tickUpper, SFUniswapV3Strategy__InvalidTicks());

        if (positionTokenId == 0) (usedUnderlying, usedOther) = _mintPosition(amountUnderlyingForLP, amountOtherForLP);
        else (usedUnderlying, usedOther) = _increaseLiquidity(amountUnderlyingForLP, amountOtherForLP);

        investedAssets = usedUnderlying;

        // TODO: 4. what to do with remainings
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

        // If requested assets are more than available, withdraw all.
        if (assets > total) assets = total;

        // 1. Compute fraction of LP to remove
        uint256 liquidityToBurn = _liquidityForValue(assets);

        if (liquidityToBurn > 0 && positionTokenId != 0) _decreaseLiquidityAndCollect(liquidityToBurn, data);

        // 2. Should have some underlying + otherToken
        uint256 balUnderlying = underlying.balanceOf(address(this));
        uint256 balOther = otherToken.balanceOf(address(this));

        // 3. swap all otherToken to underlying
        if (balOther > 0) _V3Swap(balOther, data, false);

        uint256 finalUnderlying = underlying.balanceOf(address(this));

        // 4. transfer underlying to receiver
        withdrawnAssets = finalUnderlying > assets ? assets : finalUnderlying;
        if (withdrawnAssets > 0) underlying.safeTransfer(receiver, withdrawnAssets);

        // TODO: if finalUnderlying > withdrawnAssets what to do with the rest?
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
        // TODO: compound here? or left to rebalance? if auto compound then call _increaseLiquidity()
        _collectFees(data);
    }

    function rebalance(bytes calldata data) external nonReentrant whenNotPaused onlyKeeperOrOperator {
        // `data` is expected to be: abi.encode(int24 newTickLower, int24 newTickUpper)
        (int24 newTickLower, int24 newTickUpper) = abi.decode(data, (int24, int24));

        require(newTickLower < newTickUpper, SFUniswapV3Strategy__InvalidRebalanceParams());

        int24 spacing = pool.tickSpacing();
        // Ensure the new ticks are aligned to pool.tickSpacing()
        if (newTickLower % spacing != 0 || newTickUpper % spacing != 0) {
            revert SFUniswapV3Strategy__InvalidRebalanceParams();
        }

        // If there is no active position yet, just update the range and exit.
        if (positionTokenId == 0) {
            tickLower = newTickLower;
            tickUpper = newTickUpper;
            return;
        }

        // 1. Read current liquidity and fully exit the existing position.
        uint128 currentLiquidity = PositionReader.liquidity(positionManager, positionTokenId);

        // TODO: `_data` is currently unused by `_decreaseLiquidityAndCollect`, so just pass an empty bytes blob.
        if (currentLiquidity > 0) _decreaseLiquidityAndCollect(currentLiquidity, bytes(""));

        // 2. Burn the old NFT once all liquidity has been removed.
        uint128 remainingLiquidity = PositionReader.liquidity(positionManager, positionTokenId);
        if (remainingLiquidity == 0) {
            positionManager.burn(positionTokenId);
            positionTokenId = 0;
        }

        // 3. Update the stored tick range.
        tickLower = newTickLower;
        tickUpper = newTickUpper;

        // 4. Mint a new position using whatever balances we now hold.
        uint256 balUnderlying = underlying.balanceOf(address(this));
        uint256 balOther = otherToken.balanceOf(address(this));

        // We exited but have no capital to deploy – nothing else to do.
        if (balUnderlying == 0 && balOther == 0) return;

        _mintPosition(balUnderlying, balOther);
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
            // TODO: convert idleOther -> USDC using pool price or twap or off chain oracle
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
        // TODO: check
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
        // TODO: revisit. Implementation-specific. For now: (tokenId, tickLower, tickUpper)
        return abi.encode(positionTokenId, tickLower, tickUpper);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _liquidityForValue(uint256 _value) internal pure returns (uint256) {
        // TODO: approximate how much liquidity corresponds to `value` USDC,
        // e.g. proportional to totalAssets().
        return 0;
    }

    function _mintPosition(uint256 _amountUnderlying, uint256 _amountOther)
        internal
        returns (uint256 usedUnderlying, uint256 usedOther)
    {
        // Nothing to do if both sides are zero
        if (_amountUnderlying == 0 && _amountOther == 0) return (0, 0);

        // Read pool tokens
        (address token0, address token1) = _getPoolTokens();

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
        } else {
            params.amount0Desired = _amountOther;
            params.amount1Desired = _amountUnderlying;
        }

        // TODO: do we want slippage protection for the mvp? for now handle by caller. Revisit later.
        params.amount0Min = 0;
        params.amount1Min = 0;

        // The LTH of the position will be the vault
        params.recipient = vault;
        params.deadline = block.timestamp;

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

    function _increaseLiquidity(uint256 _amountUnderlying, uint256 _amountOther)
        internal
        returns (uint256 usedUnderlying_, uint256 usedOther_)
    {
        // If there is no existing position, nothing to do
        if (positionTokenId == 0) return (0, 0);
        if (_amountUnderlying == 0 && _amountOther == 0) return (0, 0);
        // Read pool tokens
        (address token0, address token1) = _getPoolTokens();

        INonfungiblePositionManager.IncreaseLiquidityParams memory params;
        params.tokenId = positionTokenId;

        // Map desired amounts to correct tokens
        if (token0 == address(underlying)) {
            params.amount0Desired = _amountUnderlying;
            params.amount1Desired = _amountOther;
        } else {
            params.amount0Desired = _amountOther;
            params.amount1Desired = _amountUnderlying;
        }

        // TODO: do we want slippage protection for the mvp? for now handle by caller. Revisit later.
        params.amount0Min = 0;
        params.amount1Min = 0;
        params.deadline = block.timestamp;

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

    function _getPoolTokens() internal view returns (address token0_, address token1_) {
        (token0_, token1_) = (pool.token0(), pool.token1());

        // Sanity check: ensure pool tokens match expected underlying and otherToken
        require(
            (token0_ == address(underlying) && token1_ == address(otherToken))
                || (token0_ == address(otherToken) && token1_ == address(underlying)),
            SFUniswapV3Strategy__InvalidPoolTokens()
        );
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

    function _decreaseLiquidityAndCollect(uint256 _liquidity, bytes memory _data) internal {
        // TODO: use data
        if (_liquidity == 0 || positionTokenId == 0) return;

        uint128 currentLiquidity = PositionReader.liquidity(positionManager, positionTokenId);

        if (currentLiquidity == 0) return;

        uint128 liquidityToBurn;
        if (_liquidity >= currentLiquidity) {
            // Burn all liquidity
            liquidityToBurn = currentLiquidity;
        } else {
            // Burn partial liquidity, assumed the inputs is in raw units
            liquidityToBurn = uint128(_liquidity);
        }

        if (liquidityToBurn == 0) return;

        INonfungiblePositionManager.DecreaseLiquidityParams memory params;
        params.tokenId = positionTokenId;
        params.liquidity = liquidityToBurn;
        // TODO: slippage protection?
        params.amount0Min = 0;
        params.amount1Min = 0;
        params.deadline = block.timestamp;

        positionManager.decreaseLiquidity(params);

        // Collect all owed tokens (principal + fees)
        INonfungiblePositionManager.CollectParams memory collectParams;
        collectParams.tokenId = positionTokenId;
        collectParams.recipient = address(this);
        collectParams.amount0Max = type(uint128).max;
        collectParams.amount1Max = type(uint128).max;

        positionManager.collect(collectParams);
    }

    function _collectFees(bytes calldata _data) internal {
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

    function _positionValue() internal view returns (uint256) {
        if (positionTokenId == 0) return 0;

        address _token0 = PositionReader.token0(positionManager, positionTokenId);
        address _token1 = PositionReader.token1(positionManager, positionTokenId);
        int24 _tickLower = PositionReader.tickLower(positionManager, positionTokenId);
        int24 _tickUpper = PositionReader.tickUpper(positionManager, positionTokenId);
        uint128 _liquidity = PositionReader.liquidity(positionManager, positionTokenId);

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

    /// @dev Quotes `_amountOther` in units of `underlying` using the current pool spot price from `slot0`.
    function _quoteOtherAsUnderlying(uint256 _amountOther) internal view returns (uint256) {
        if (_amountOther == 0) return 0;

        // Get the tokens in the pool
        (address _token0, address _token1) = _getPoolTokens();

        if (address(underlying) == address(otherToken)) return _amountOther;

        // slot0 returns sqrtPriceX96 where price = token1 / token0 = (sqrtPriceX96^2) / 2^192
        (uint160 _sqrtPriceX96,,,,,,) = pool.slot0();

        uint256 _priceX192 = uint256(_sqrtPriceX96) * uint256(_sqrtPriceX96);
        uint256 _q192 = 1 << 192;

        if (address(otherToken) == _token0 && address(underlying) == _token1) {
            // other = token0, underlying = token1
            // valueInUnderlying = amountOther * price (token1 per token0)
            return FullMath.mulDiv(_amountOther, _priceX192, _q192);
        } else if (address(otherToken) == _token1 && address(underlying) == _token0) {
            // other = token1, underlying = token0
            // valueInUnderlying = amountOther / price
            return FullMath.mulDiv(_amountOther, _q192, _priceX192);
        } else {
            // TODO: is this reachable? revisit
            revert SFUniswapV3Strategy__InvalidPoolTokens();
        }
    }

    /// @dev required by the OZ UUPS module.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.OPERATOR) {}
}
