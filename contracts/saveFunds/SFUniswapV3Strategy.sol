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
    bool public rangeInitialized;

    struct DepositParams {
        bytes[] swapToOtherInputs; // underlying -> other
        bytes[] swapBackInputs; // other -> underlying (for leftovers)
        uint256 swapDeadline; // router deadline (0 => block.timestamp)
        uint16 otherRatioBps; // portion of assets swapped to other
        uint128 minUnderlyingUsed; // mint/increase slippage mins
        uint128 minOtherUsed;
        uint256 lpDeadline; // mint/increase deadline (0 => block.timestamp)
    }

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnMaxTVLUpdated(uint256 oldMaxTVL, uint256 newMaxTVL);
    event OnRangeUpdated(int24 oldLower, int24 oldUpper, int24 newLower, int24 newUpper);

    error SFUniswapV3Strategy__NotAuthorizedCaller();
    error SFUniswapV3Strategy__NotAddressZero();
    error SFUniswapV3Strategy__NotZeroAmount();
    error SFUniswapV3Strategy__MaxTVLReached();
    error SFUniswapV3Strategy__InvalidPoolTokens();
    error SFUniswapV3Strategy__UnexpectedPositionTokenId();
    error SFUniswapV3Strategy__InvalidRebalanceParams();
    error SFUniswapV3Strategy__RangeNotInitialized();
    error SFUniswapV3Strategy__InvalidTick();
    error SFUniswapV3Strategy__InvalidDepositData();
    error SFUniswapV3Strategy__InvalidOtherRatioBps();
    error SFUniswapV3Strategy__MissingSwapBackData();
    error SFUniswapV3Strategy__SwapBackIncomplete();
    error SFUniswapV3Strategy__FlushIdleToVaultIncomplete();
    error SFUniswapV3Strategy__InvalidReceiver();

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
        int24 _initialTickLower,
        int24 _initialTickUpper
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

        _setRange(_initialTickLower, _initialTickUpper);
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

    /**
     * @notice Emergency exit function to withdraw all assets and pause the strategy
     * @param receiver The address to receive the withdrawn underlying assets.
     * @dev This needs the vault to approve this strategy to be able to burn.
     */
    function emergencyExit(address receiver) external notAddressZero(receiver) onlyRole(Roles.OPERATOR) {
        // withdraw all
        if (positionTokenId != 0) {
            _decreaseLiquidityAndCollect(type(uint128).max, bytes(""));

            uint128 remainingLiquidity = PositionReader.liquidity(positionManager, positionTokenId);
            if (remainingLiquidity == 0) {
                positionManager.burn(positionTokenId);
                positionTokenId = 0;
            }
        }

        // swap all otherToken to underlying
        uint256 balOther = otherToken.balanceOf(address(this));

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
     * @param assets The amount of underlying assets to deposit.
     * @param data is abi.encode deposit params
     */
    function deposit(uint256 assets, bytes calldata data)
        external
        onlyContract("PROTOCOL__SF_VAULT")
        nonReentrant
        whenNotPaused
        returns (uint256 investedAssets)
    {
        require(assets > 0, SFUniswapV3Strategy__NotZeroAmount());
        require(maxTVL == 0 || totalAssets() + assets <= maxTVL, SFUniswapV3Strategy__MaxTVLReached());

        underlying.safeTransferFrom(msg.sender, address(this), assets);

        DepositParams memory p = _decodeDepositParams(data);

        uint256 toSwap = (assets * uint256(p.otherRatioBps)) / MAX_BPS;
        uint256 balUnderlyingBefore = underlying.balanceOf(address(this));
        if (toSwap > balUnderlyingBefore) toSwap = balUnderlyingBefore;

        if (toSwap > 0 && p.swapToOtherInputs.length > 0) {
            _V3Swap(toSwap, p.swapToOtherInputs, p.swapDeadline, true); // underlying -> other
        }

        uint256 balUnderlying = underlying.balanceOf(address(this));
        uint256 balOther = otherToken.balanceOf(address(this));

        uint256 lpDeadline = p.lpDeadline == 0 ? block.timestamp : p.lpDeadline;

        if (positionTokenId == 0) {
            _mintPosition(balUnderlying, balOther, p.minUnderlyingUsed, p.minOtherUsed, lpDeadline);
        } else {
            _increaseLiquidity(balUnderlying, balOther, p.minUnderlyingUsed, p.minOtherUsed, lpDeadline);
        }

        uint256 refunded = _flushIdleToVault(p.swapBackInputs, p.swapDeadline);

        investedAssets = assets > refunded ? (assets - refunded) : 0;
    }

    /**
     * @notice Withdraw assets from Uniswap V3 LP position.
     * @dev Tries to realize `assets` worth of underlying, may return less in edge cases.
     * @param assets The amount of underlying assets to withdraw.
     * @param receiver The address to receive the withdrawn underlying assets.
     * @param data is abi.encode(bytes[] inputs, uint256 deadline)
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

        // Enforce that strategy only ever sends funds back to the vault.
        require(receiver == vault, SFUniswapV3Strategy__InvalidReceiver());

        uint256 total = totalAssets();
        if (total == 0) return 0;

        if (assets > total) assets = total;

        // 1) Compute fraction of LP to remove
        uint256 liquidityToBurn = _liquidityForValue(assets);

        // 2) Exit liquidity + collect
        if (positionTokenId != 0 && liquidityToBurn > 0) {
            _decreaseLiquidityAndCollect(liquidityToBurn, bytes(""));
        }

        // 3) Swap all otherToken -> underlying (must provide swapBack inputs if otherToken exists)
        uint256 balOther = otherToken.balanceOf(address(this));
        if (balOther > 0) {
            require(data.length != 0, SFUniswapV3Strategy__MissingSwapBackData());

            (bytes[] memory inputs, uint256 deadline) = abi.decode(data, (bytes[], uint256));
            _V3Swap(balOther, inputs, deadline, false);

            // enforce "no assets held" — bad swap data must revert
            require(otherToken.balanceOf(address(this)) == 0, SFUniswapV3Strategy__SwapBackIncomplete());
        }

        // 4) Send ALL underlying back to vault so strategy ends with 0 idle balances
        uint256 finalUnderlying = underlying.balanceOf(address(this));
        withdrawnAssets = finalUnderlying;

        if (finalUnderlying > 0) {
            underlying.safeTransfer(vault, finalUnderlying);
        }

        require(underlying.balanceOf(address(this)) == 0, "idle underlying remains");
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
        int24 newTickLower;
        int24 newTickUpper;
        uint128 minUnderlyingUsed;
        uint128 minOtherUsed;
        uint256 lpDeadline;

        if (data.length == 64) {
            (newTickLower, newTickUpper) = abi.decode(data, (int24, int24));
            lpDeadline = block.timestamp;
        } else {
            (newTickLower, newTickUpper, minUnderlyingUsed, minOtherUsed, lpDeadline) =
                abi.decode(data, (int24, int24, uint128, uint128, uint256));

            if (lpDeadline == 0) lpDeadline = block.timestamp;
        }

        require(newTickLower < newTickUpper, SFUniswapV3Strategy__InvalidRebalanceParams());

        int24 spacing = pool.tickSpacing();
        require(
            newTickLower % spacing == 0 && newTickUpper % spacing == 0, SFUniswapV3Strategy__InvalidRebalanceParams()
        );

        // If there is no active position yet, just update the range and exit.
        if (positionTokenId == 0) {
            _setRange(newTickLower, newTickUpper);
            return;
        }

        // 1) Exit + collect (collect is important even if liquidity == 0)
        uint128 currentLiquidity = PositionReader.liquidity(positionManager, positionTokenId);

        _decreaseLiquidityAndCollect(currentLiquidity, bytes(""));

        // 2) Burn old NFT if empty (requires vault approval for the strategy on positionManager)
        uint128 remainingLiquidity = PositionReader.liquidity(positionManager, positionTokenId);
        if (remainingLiquidity == 0) {
            positionManager.burn(positionTokenId);
            positionTokenId = 0;
        }

        // 3) Update range
        _setRange(newTickLower, newTickUpper);

        // 4) Mint new position with whatever balances we now hold
        uint256 balUnderlying = underlying.balanceOf(address(this));
        uint256 balOther = otherToken.balanceOf(address(this));

        if (balUnderlying == 0 && balOther == 0) return;

        _mintPosition(balUnderlying, balOther, minUnderlyingUsed, minOtherUsed, lpDeadline);
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

    function getRange() external view returns (int24 lower, int24 upper, bool initialized) {
        return (tickLower, tickUpper, rangeInitialized);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _decodeDepositParams(bytes calldata data) internal pure returns (DepositParams memory p) {
        p.otherRatioBps = uint16(MAX_BPS / 2);

        if (data.length == 0) return p;

        (
            p.swapToOtherInputs,
            p.swapBackInputs,
            p.swapDeadline,
            p.otherRatioBps,
            p.minUnderlyingUsed,
            p.minOtherUsed,
            p.lpDeadline
        ) = abi.decode(data, (bytes[], bytes[], uint256, uint16, uint128, uint128, uint256));

        require(p.otherRatioBps <= MAX_BPS, SFUniswapV3Strategy__InvalidDepositData());
    }

    function _liquidityForValue(uint256 _value) internal pure returns (uint256) {
        // TODO: approximate how much liquidity corresponds to `value` USDC,
        // e.g. proportional to totalAssets().
        return 0;
    }

    function _mintPosition(
        uint256 amountUnderlying,
        uint256 amountOther,
        uint128 minUnderlyingUsed,
        uint128 minOtherUsed,
        uint256 deadline
    ) internal returns (uint256 usedUnderlying, uint256 usedOther) {
        if (amountUnderlying == 0 && amountOther == 0) return (0, 0);

        (address token0, address token1) = _getPoolTokens();

        INonfungiblePositionManager.MintParams memory params;
        params.token0 = token0;
        params.token1 = token1;
        params.fee = pool.fee();
        params.tickLower = tickLower;
        params.tickUpper = tickUpper;
        params.recipient = vault;
        params.deadline = deadline;

        if (token0 == address(underlying)) {
            params.amount0Desired = amountUnderlying;
            params.amount1Desired = amountOther;
            params.amount0Min = uint256(minUnderlyingUsed);
            params.amount1Min = uint256(minOtherUsed);
        } else {
            params.amount0Desired = amountOther;
            params.amount1Desired = amountUnderlying;
            params.amount0Min = uint256(minOtherUsed);
            params.amount1Min = uint256(minUnderlyingUsed);
        }

        if (params.amount0Desired > 0) {
            IERC20(params.token0).forceApprove(address(positionManager), params.amount0Desired);
        }
        if (params.amount1Desired > 0) {
            IERC20(params.token1).forceApprove(address(positionManager), params.amount1Desired);
        }

        (uint256 tokenId,, uint256 amount0, uint256 amount1) = positionManager.mint(params);

        // First mint stores tokenId
        if (positionTokenId == 0) positionTokenId = tokenId;
        else require(tokenId == positionTokenId, SFUniswapV3Strategy__UnexpectedPositionTokenId());

        if (token0 == address(underlying)) {
            usedUnderlying = amount0;
            usedOther = amount1;
        } else {
            usedUnderlying = amount1;
            usedOther = amount0;
        }
    }

    function _increaseLiquidity(
        uint256 amountUnderlying,
        uint256 amountOther,
        uint128 minUnderlyingUsed,
        uint128 minOtherUsed,
        uint256 deadline
    ) internal returns (uint256 usedUnderlying, uint256 usedOther) {
        if (positionTokenId == 0) return (0, 0);
        if (amountUnderlying == 0 && amountOther == 0) return (0, 0);

        (address token0, address token1) = _getPoolTokens();

        INonfungiblePositionManager.IncreaseLiquidityParams memory params;
        params.tokenId = positionTokenId;
        params.deadline = deadline;

        if (token0 == address(underlying)) {
            params.amount0Desired = amountUnderlying;
            params.amount1Desired = amountOther;
            params.amount0Min = uint256(minUnderlyingUsed);
            params.amount1Min = uint256(minOtherUsed);
        } else {
            params.amount0Desired = amountOther;
            params.amount1Desired = amountUnderlying;
            params.amount0Min = uint256(minOtherUsed);
            params.amount1Min = uint256(minUnderlyingUsed);
        }

        // approve BOTH sides if needed
        if (params.amount0Desired > 0) IERC20(token0).forceApprove(address(positionManager), params.amount0Desired);
        if (params.amount1Desired > 0) IERC20(token1).forceApprove(address(positionManager), params.amount1Desired);

        (, uint256 amount0, uint256 amount1) = positionManager.increaseLiquidity(params);

        if (token0 == address(underlying)) {
            usedUnderlying = amount0;
            usedOther = amount1;
        } else {
            usedUnderlying = amount1;
            usedOther = amount0;
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
     * @param _zeroForOne If true: swap `underlying -> otherToken`.
     *                    If false: swap `otherToken -> underlying`.
     *                    Not necessarily pool.token0 -> pool.token1.
     */
    function _V3Swap(uint256 _amountIn, bytes[] memory _inputs, uint256 _deadline, bool _zeroForOne) internal {
        if (_amountIn == 0) return;
        if (_inputs.length == 0) return;

        if (_deadline == 0) _deadline = block.timestamp;

        bytes memory commands = new bytes(_inputs.length);
        for (uint256 i = 0; i < _inputs.length; ++i) {
            commands[i] = bytes1(uint8(Commands.V3_SWAP_EXACT_IN));
        }

        if (_zeroForOne) {
            underlying.forceApprove(address(universalRouter), _amountIn);
        } else {
            otherToken.forceApprove(address(universalRouter), _amountIn);
        }

        universalRouter.execute(commands, _inputs, _deadline);

        // Optional (safer): clear approval
        if (_zeroForOne) {
            underlying.forceApprove(address(universalRouter), 0);
        } else {
            otherToken.forceApprove(address(universalRouter), 0);
        }
    }

    function _decreaseLiquidityAndCollect(uint256 _liquidity, bytes memory _data) internal {
        // TODO: use data
        if (_liquidity == 0 || positionTokenId == 0) return;

        uint128 currentLiquidity = PositionReader.liquidity(positionManager, positionTokenId);

        if (_liquidity != 0 && currentLiquidity != 0) {
            uint128 liquidityToBurn;
            if (_liquidity >= currentLiquidity) {
                // Burn all liquidity
                liquidityToBurn = currentLiquidity;
            } else {
                // Burn partial liquidity, assumed the inputs is in raw units
                liquidityToBurn = uint128(_liquidity);
            }

            INonfungiblePositionManager.DecreaseLiquidityParams memory params;
            params.tokenId = positionTokenId;
            params.liquidity = liquidityToBurn;
            // TODO: slippage protection?
            params.amount0Min = 0;
            params.amount1Min = 0;
            params.deadline = block.timestamp;

            positionManager.decreaseLiquidity(params);
        }

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

    function _setRange(int24 _newLower, int24 _newUpper) internal {
        require(_newLower < _newUpper, SFUniswapV3Strategy__InvalidRebalanceParams());

        int24 spacing = pool.tickSpacing();
        require(_newLower % spacing == 0 && _newUpper % spacing == 0, SFUniswapV3Strategy__InvalidRebalanceParams());
        require(_newLower >= TickMath.MIN_TICK && _newUpper <= TickMath.MAX_TICK, SFUniswapV3Strategy__InvalidTick());

        emit OnRangeUpdated(tickLower, tickUpper, _newLower, _newUpper);
        tickLower = _newLower;
        tickUpper = _newUpper;
        rangeInitialized = true;
    }

    function _flushIdleToVault(bytes[] memory swapBackInputs, uint256 swapDeadline)
        internal
        returns (uint256 refundedUnderlying)
    {
        uint256 balOther = otherToken.balanceOf(address(this));

        if (balOther > 0) {
            require(swapBackInputs.length != 0, SFUniswapV3Strategy__MissingSwapBackData());

            // Swap ALL leftover other -> underlying
            _V3Swap(balOther, swapBackInputs, swapDeadline, false);

            // Enforce that we didn’t leave any otherToken dust behind due to bad inputs
            require(otherToken.balanceOf(address(this)) == 0, SFUniswapV3Strategy__SwapBackIncomplete());
        }

        refundedUnderlying = underlying.balanceOf(address(this));
        if (refundedUnderlying > 0) {
            underlying.safeTransfer(vault, refundedUnderlying);
        }

        require(underlying.balanceOf(address(this)) == 0, SFUniswapV3Strategy__FlushIdleToVaultIncomplete());
    }

    /// @dev required by the OZ UUPS module.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.OPERATOR) {}
}
