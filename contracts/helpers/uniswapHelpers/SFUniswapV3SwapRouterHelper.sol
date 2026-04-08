// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFUniswapV3SwapRouterHelper
 * @author Maikel Ordaz
 * @notice Stateless route builder used by `SFUniswapV3Strategy` to keep strategy runtime size smaller.
 * @dev There are two possible routes that can be built and quoted through this helper:
 *     `1`: Direct Uniswap V3 single-hop swap with fee 100. (Always enabled).
 *     `2`: Direct Uniswap V4 single-hop swap using the configured pool metadata.
 *     If there is no Uniswap V4 pool configured, then Uniswap V3 will always be selected.
 *     If there is a V4 pool configured, the strategy will select the best route by quoting both and comparing
 *     the best outputs.
 */

pragma solidity 0.8.28;

import {Commands} from "contracts/helpers/uniswapHelpers/libraries/Commands.sol";
import {UniswapV3Swap} from "contracts/helpers/uniswapHelpers/libraries/UniswapV3Swap.sol";
import {UniswapV4Swap} from "contracts/helpers/uniswapHelpers/libraries/UniswapV4Swap.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ISFUniswapV3SwapRouterHelper} from "contracts/interfaces/helpers/ISFUniswapV3SwapRouterHelper.sol";
import {RouteSelection, SwapExecution, SwapRouteData} from "contracts/types/SwapRoutes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPermit2AllowanceTransfer} from "contracts/interfaces/helpers/IPermit2AllowanceTransfer.sol";
import {IUniversalRouter} from "contracts/interfaces/helpers/IUniversalRouter.sol";

contract SFUniswapV3SwapRouterHelper is ISFUniswapV3SwapRouterHelper {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    IAddressManager internal immutable addressManager;
    uint24 internal swapV4PoolFee;
    int24 internal swapV4PoolTickSpacing;
    address internal swapV4PoolHooks;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint24 internal constant SINGLE_HOP_V3_FEE = 100;
    uint8 internal constant ROUTE_V3_SINGLE_HOP = 1;
    uint8 internal constant ROUTE_V4_SINGLE_HOP = 2;
    uint8 internal constant MAX_ROUTE_CANDIDATES = 2;
    uint16 internal constant MAX_BPS = 10_000;
    uint256 internal constant AMOUNT_IN_BPS_FLAG = 1 << 255; // When the high bit is set, the low 16 bits encode a BPS value instead of a literal amount.
    uint256 internal constant AMOUNT_IN_BPS_MASK = 0xFFFF; // BPS fits in 16 bits, so the strategy uses the low 16 bits as the encoded percentage payload.
    bytes4 internal constant QUOTED_ROUTE_OUTPUT_ERROR_SELECTOR =
        bytes4(keccak256("SFUniswapV3Strategy__QuotedRouteOutput(uint256)"));

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnSwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    error SFUniswapV3SwapRouterHelper__NotStrategy();
    error SFUniswapV3SwapRouterHelper__NotStrategyContext();
    error SFUniswapV3Strategy__InvalidStrategyData();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyStrategy() {
        require(msg.sender == _strategyAddress(), SFUniswapV3SwapRouterHelper__NotStrategy());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Stores immutable context required to build and execute background swap routes.
     * @param addressManager_ AddressManager resolver used to look up the canonical strategy proxy.
     * @custom:invariant The helper must always resolve the active strategy proxy through AddressManager instead of
     *                   caching the strategy address or token pair locally.
     */
    constructor(address addressManager_) {
        addressManager = IAddressManager(addressManager_);
    }

    /*//////////////////////////////////////////////////////////////
                                SETTINGS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Stores the direct Uniswap V4 pool metadata used by route `2`.
     * @dev Callable only by the strategy resolved through AddressManager.
     *      Zero `fee` or `tickSpacing` intentionally disables the V4 candidate route.
     * @param fee Uniswap V4 pool fee in hundredths of a bip.
     * @param tickSpacing Tick spacing for the configured V4 pool.
     * @param hooks Hook contract configured for the pool, or `address(0)`.
     * @custom:invariant This helper only stores swap-route metadata; it never stores LP position state.
     */
    function setSwapV4PoolConfig(uint24 fee, int24 tickSpacing, address hooks) external onlyStrategy {
        // Route `2` is driven entirely by this metadata, so clearing it disables the V4 candidate.
        swapV4PoolFee = fee;
        swapV4PoolTickSpacing = tickSpacing;
        swapV4PoolHooks = hooks;
    }

    /*//////////////////////////////////////////////////////////////
                           RESOLVE AND BUILD
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Decodes and validates the compact route bundle used for background swaps.
     * @param swapData ABI-encoded route payload:
     *        `abi.encode(uint256 amountIn, uint256 deadline, uint8 routeCount, uint8[2] routeIds, uint256[2] amountOutMins)`.
     * @return routeData_ Decoded and validated route bundle.
     * @custom:invariant Only one V3 candidate and one V4 candidate can be present, and unused slots must stay zeroed.
     */
    function decodeSwapRouteData(bytes calldata swapData) external pure returns (SwapRouteData memory routeData_) {
        (
            routeData_.amountIn,
            routeData_.deadline,
            routeData_.routeCount,
            routeData_.routeIds,
            routeData_.amountOutMins
        ) = abi.decode(swapData, (uint256, uint256, uint8, uint8[2], uint256[2]));

        // Every background swap must request a non-zero amount and at least one candidate route.
        require(routeData_.amountIn != 0, SFUniswapV3Strategy__InvalidStrategyData());
        require(
            routeData_.routeCount > 0 && routeData_.routeCount <= MAX_ROUTE_CANDIDATES,
            SFUniswapV3Strategy__InvalidStrategyData()
        );

        // Route ids are 1-based (`1 = V3`, `2 = V4`), so slot `0` is intentionally unused.
        bool[3] memory seenRoutes;
        for (uint256 i; i < MAX_ROUTE_CANDIDATES; ++i) {
            uint8 routeId = routeData_.routeIds[i];
            if (i < routeData_.routeCount) {
                // Populated slots must reference one of the two canonical routes and cannot repeat the same route.
                require(
                    routeId >= ROUTE_V3_SINGLE_HOP && routeId <= ROUTE_V4_SINGLE_HOP,
                    SFUniswapV3Strategy__InvalidStrategyData()
                );
                require(!seenRoutes[routeId], SFUniswapV3Strategy__InvalidStrategyData());
                seenRoutes[routeId] = true;
            } else {
                // Unused slots are required to stay fully zeroed so there is only one canonical encoding.
                require(routeId == 0 && routeData_.amountOutMins[i] == 0, SFUniswapV3Strategy__InvalidStrategyData());
            }
        }
    }

    /**
     * @notice Resolves the effective exact-input amount for a swap.
     * @dev If the high-bit sentinel is present, the low 16 bits are interpreted as basis points of `availableAmount`.
     *      Otherwise the value is treated as a literal token amount.
     * @param requestedAmountIn Encoded literal amount or BPS-sentinel amount.
     * @param availableAmount Runtime amount available for the swap direction.
     * @return amountIn_ Exact input amount that should be quoted/executed.
     * @custom:invariant Returned amount must be strictly positive and must decode to at most 10_000 BPS.
     */
    function resolveSwapAmountIn(uint256 requestedAmountIn, uint256 availableAmount)
        external
        pure
        returns (uint256 amountIn_)
    {
        amountIn_ = requestedAmountIn;
        if ((requestedAmountIn & AMOUNT_IN_BPS_FLAG) != 0) {
            // High-bit sentinel means "swap this many BPS of the runtime-available balance".
            uint256 bps = requestedAmountIn & AMOUNT_IN_BPS_MASK;
            require(bps <= MAX_BPS, SFUniswapV3Strategy__InvalidStrategyData());
            amountIn_ = (availableAmount * bps) / MAX_BPS;
        }

        // Literal amounts and BPS-resolved amounts both need to stay non-zero.
        require(amountIn_ > 0, SFUniswapV3Strategy__InvalidStrategyData());
    }

    /**
     * @notice Builds the Universal Router execution bundle for one candidate route.
     * @param recipient Recipient passed to the route builder when the route needs it.
     * @param routeId Candidate route id (`1 = V3`, `2 = V4`).
     * @param amountIn Exact input amount for the swap.
     * @param amountOutMin Minimum acceptable output for the candidate route.
     * @param swapToOther True for `underlying -> otherToken`, false for `otherToken -> underlying`.
     * @return execution_ Prepared route execution; empty when the route is currently disabled.
     * @custom:invariant A disabled route must return an empty execution instead of reverting so the strategy can
     *                   continue evaluating the remaining candidate.
     */
    function buildRouteExecution(
        address recipient,
        uint8 routeId,
        uint256 amountIn,
        uint256 amountOutMin,
        bool swapToOther
    ) external view returns (SwapExecution memory execution_) {
        // The helper never owns the pair config; it always asks the strategy for the current canonical tokens.
        (address underlying_, address otherToken_) = _strategyTokens();

        if (routeId == ROUTE_V3_SINGLE_HOP) {
            return _buildV3RouteExecution(recipient, amountIn, amountOutMin, swapToOther, underlying_, otherToken_);
        }
        if (routeId == ROUTE_V4_SINGLE_HOP) {
            return _buildV4RouteExecution(amountIn, amountOutMin, swapToOther, underlying_, otherToken_);
        }
        return execution_;
    }

    /*//////////////////////////////////////////////////////////////
                           SELECT AND EXECUTE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Quotes each requested route onchain and returns the best viable candidate.
     * @dev Callable only by the strategy resolved through AddressManager.
     *      The strategy already computed `twapMinOut`; this function simply enforces the higher of the candidate floor
     *      and the shared TWAP floor before selecting the best quoted route.
     * @param routeCount Number of populated entries in `routeIds`/`amountOutMins`.
     * @param routeIds Candidate route ids to evaluate.
     * @param amountOutMins Candidate min-out floors aligned to `routeIds`.
     * @param amountIn Exact input amount to quote for every candidate.
     * @param deadline Universal Router deadline used during quoting.
     * @param twapMinOut Shared TWAP-derived floor computed by the strategy.
     * @param swapToOther True for `underlying -> otherToken`, false for `otherToken -> underlying`.
     * @return selection_ Best viable route plus the per-route quoted outputs used for observability.
     * @custom:invariant The selected route, if any, must be the highest quoted output that satisfies its floor.
     */
    function selectBestRoute(
        uint8 routeCount,
        uint8[2] memory routeIds,
        uint256[2] memory amountOutMins,
        uint256 amountIn,
        uint256 deadline,
        uint256 twapMinOut,
        bool swapToOther
    ) external onlyStrategy returns (RouteSelection memory selection_) {
        uint256 bestQuotedOut;

        for (uint256 i; i < routeCount; ++i) {
            uint8 routeId = routeIds[i];
            uint256 amountOutMin = amountOutMins[i];

            // Every candidate is held to the stricter of its own explicit floor and the shared TWAP floor.
            if (twapMinOut > amountOutMin) amountOutMin = twapMinOut;

            // Quote every requested route against the same exact-input amount before choosing the best candidate.
            uint256 quotedOut = _quoteRouteOutput(routeId, amountIn, deadline, swapToOther);
            if (routeId == ROUTE_V3_SINGLE_HOP) selection_.v3QuotedOut = quotedOut;
            else if (routeId == ROUTE_V4_SINGLE_HOP) selection_.v4QuotedOut = quotedOut;

            // Routes that fail to quote, miss minOut, or do not improve on the current best quote are ignored.
            if (quotedOut < amountOutMin || quotedOut <= bestQuotedOut) continue;

            bestQuotedOut = quotedOut;
            selection_.bestAmountOutMin = amountOutMin;
            selection_.bestRouteId = routeId;
        }
    }

    /**
     * @notice Executes a prepared route bundle through Universal Router from the strategy context.
     * @dev Must be reached through `delegatecall` from the strategy so approvals and balances stay in strategy state.
     * @param permit2Address Permit2 contract used by Universal Router allowances.
     * @param universalRouterAddress Universal Router used to execute the prepared commands.
     * @param tokenInAddress Input token address for the swap.
     * @param expectedOut Output token address whose balance delta will be measured.
     * @param commands Universal Router command bytes.
     * @param inputs Universal Router encoded inputs aligned to `commands`.
     * @param totalIn Total input amount expected to be pulled by the route.
     * @param deadline Universal Router deadline for the execution.
     * @param emitEvents Whether to emit `OnSwapExecuted` for this execution.
     * @return ok_ True when the router call succeeded.
     * @return amountOut_ Measured output balance delta for `expectedOut`.
     * @custom:invariant The helper must leave router approvals for `tokenInAddress` reset to zero after execution.
     */
    function executePreparedSwap(
        address permit2Address,
        address universalRouterAddress,
        address tokenInAddress,
        address expectedOut,
        bytes memory commands,
        bytes[] memory inputs,
        uint256 totalIn,
        uint256 deadline,
        bool emitEvents
    ) external returns (bool ok_, uint256 amountOut_) {
        // This path is intentionally reachable only through `delegatecall` from the strategy. That guarantees the
        // helper is operating over strategy balances/approvals rather than its own empty account.
        require(address(this) == _strategyAddress(), SFUniswapV3SwapRouterHelper__NotStrategyContext());

        IERC20 tokenIn = IERC20(tokenInAddress);
        // If the strategy no longer holds the required input amount, the route is treated as unusable.
        if (tokenIn.balanceOf(address(this)) < totalIn) return (false, 0);

        _ensurePermit2Max(tokenIn, permit2Address, universalRouterAddress);
        tokenIn.forceApprove(universalRouterAddress, totalIn);

        // Measure output by balance delta so both V3 and V4 routes share the same accounting path.
        uint256 outBefore = IERC20(expectedOut).balanceOf(address(this));
        (ok_,) = universalRouterAddress.call(
            abi.encodeWithSelector(IUniversalRouter.execute.selector, commands, inputs, deadline)
        );

        if (ok_) {
            uint256 outAfter = IERC20(expectedOut).balanceOf(address(this));
            amountOut_ = outAfter - outBefore;
            if (emitEvents) emit OnSwapExecuted(tokenInAddress, expectedOut, totalIn, amountOut_);
        }

        // Reset the direct router approval even on success so the helper keeps the approval surface minimal.
        tokenIn.forceApprove(universalRouterAddress, 0);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Returns the strategy proxy resolved through AddressManager.
     * @custom:invariant The helper must always treat AddressManager as the source of truth for the strategy address.
     */
    function _strategyAddress() internal view returns (address strategy_) {
        // AddressManager is the single source of truth for the canonical strategy proxy in this deployment.
        strategy_ = addressManager.getProtocolAddressByName("PROTOCOL__SF_UNISWAP_V3_STRATEGY").addr;
    }

    /**
     * @dev Returns the token pair configured on the strategy itself.
     * @return underlying_ Underlying token returned by the strategy `asset()` view.
     * @return otherToken_ Paired token returned by the strategy `otherToken()` view.
     * @custom:invariant The helper must use the strategy as the source of truth for the swap pair.
     */
    function _strategyTokens() internal view returns (address underlying_, address otherToken_) {
        address strategy_ = _strategyAddress();

        // Resolve the pair from the strategy itself so helper deployments do not need to duplicate token config.
        (bool okUnderlying, bytes memory underlyingData) = strategy_.staticcall(abi.encodeWithSignature("asset()"));
        (bool okOther, bytes memory otherData) = strategy_.staticcall(abi.encodeWithSignature("otherToken()"));

        require(
            okUnderlying && underlyingData.length >= 32 && okOther && otherData.length >= 32,
            SFUniswapV3Strategy__InvalidStrategyData()
        );

        underlying_ = abi.decode(underlyingData, (address));
        otherToken_ = abi.decode(otherData, (address));
        require(underlying_ != address(0) && otherToken_ != address(0), SFUniswapV3Strategy__InvalidStrategyData());
    }

    /**
     * @dev Builds the direct V3 exact-in route used by route `1`.
     * @param recipient Recipient encoded into the V3 Universal Router input.
     * @param amountIn Exact input amount.
     * @param amountOutMin Minimum output accepted by the route.
     * @param swapToOther True for `underlying -> otherToken`, false for `otherToken -> underlying`.
     * @param underlying_ Underlying token resolved from the strategy.
     * @param otherToken_ Paired token resolved from the strategy.
     * @return execution_ Prepared direct V3 route execution.
     */
    function _buildV3RouteExecution(
        address recipient,
        uint256 amountIn,
        uint256 amountOutMin,
        bool swapToOther,
        address underlying_,
        address otherToken_
    ) internal pure returns (SwapExecution memory execution_) {
        address tokenIn = swapToOther ? underlying_ : otherToken_;
        address tokenOut = swapToOther ? otherToken_ : underlying_;

        // Route `1` is a single direct V3 exact-in hop with the fixed fee-100 stable pool.
        execution_.tokenIn = tokenIn;
        execution_.tokenOut = tokenOut;
        execution_.commands = abi.encodePacked(bytes1(uint8(Commands.V3_SWAP_EXACT_IN)));
        execution_.inputs = new bytes[](1);
        execution_.inputs[0] = UniswapV3Swap.buildUniversalRouterExactInInput(
            recipient,
            amountIn,
            amountOutMin,
            UniswapV3Swap.buildSingleHopPath(tokenIn, SINGLE_HOP_V3_FEE, tokenOut),
            true
        );
        execution_.totalIn = amountIn;
    }

    /**
     * @dev Builds the direct V4 exact-in route used by route `2`.
     * @param amountIn Exact input amount.
     * @param amountOutMin Minimum output accepted by the route.
     * @param swapToOther True for `underlying -> otherToken`, false for `otherToken -> underlying`.
     * @param underlying_ Underlying token resolved from the strategy.
     * @param otherToken_ Paired token resolved from the strategy.
     * @return execution_ Prepared direct V4 route execution, or an empty struct when route `2` is disabled.
     */
    function _buildV4RouteExecution(
        uint256 amountIn,
        uint256 amountOutMin,
        bool swapToOther,
        address underlying_,
        address otherToken_
    ) internal view returns (SwapExecution memory execution_) {
        address tokenIn = swapToOther ? underlying_ : otherToken_;
        address tokenOut = swapToOther ? otherToken_ : underlying_;

        // Missing V4 pool metadata means route `2` is disabled and should be skipped by the selector.
        if (swapV4PoolFee == 0 || swapV4PoolTickSpacing == 0) return execution_;

        execution_.tokenIn = tokenIn;
        execution_.tokenOut = tokenOut;
        execution_.commands = abi.encodePacked(bytes1(uint8(Commands.V4_SWAP)));
        execution_.inputs = new bytes[](1);
        execution_.totalIn = amountIn;

        // The pool key is rebuilt on demand so the V4 route always reflects the latest configured pool metadata.
        UniswapV4Swap.PoolKey memory poolKey =
            UniswapV4Swap.buildPoolKey(underlying_, otherToken_, swapV4PoolFee, swapV4PoolTickSpacing, swapV4PoolHooks);
        execution_.inputs[0] = UniswapV4Swap.buildUniversalRouterExactInSingleInput(
            poolKey, tokenIn == poolKey.currency0, uint128(amountIn), uint128(amountOutMin), amountIn, amountOutMin
        );
    }

    /**
     * @dev Asks the strategy to simulate one candidate route and returns the quoted output encoded in revert data.
     * @param routeId Candidate route id to quote.
     * @param amountIn Exact input amount to quote.
     * @param deadline Universal Router deadline to use for the quote simulation.
     * @param swapToOther True for `underlying -> otherToken`, false for `otherToken -> underlying`.
     * @return amountOut_ Quoted output amount, or zero when the quote call failed or used an unexpected revert shape.
     */
    function _quoteRouteOutput(uint8 routeId, uint256 amountIn, uint256 deadline, bool swapToOther)
        internal
        returns (uint256 amountOut_)
    {
        // The strategy simulates the chosen route and intentionally reverts with the quoted amount embedded in the
        // revert data so all intermediate router side effects are rolled back.
        (bool ok, bytes memory returndata) = _strategyAddress()
            .call(
                abi.encodeWithSignature(
                    "quoteRouteOutput(uint8,uint256,uint256,bool)", routeId, amountIn, deadline, swapToOther
                )
            );
        if (ok || returndata.length < 36) return 0;

        bytes4 selector;
        assembly {
            selector := mload(add(returndata, 0x20))
        }
        // Any unexpected revert shape is treated as a failed quote.
        if (selector != QUOTED_ROUTE_OUTPUT_ERROR_SELECTOR) return 0;

        assembly {
            amountOut_ := mload(add(returndata, 0x24))
        }
    }

    /**
     * @dev Ensures Permit2 can grant Universal Router the maximum allowance for `tokenIn`.
     * @param tokenIn Input token used by the prepared route.
     * @param permit2Address Permit2 contract used by Universal Router.
     * @param universalRouterAddress Universal Router that will pull `tokenIn`.
     * @custom:invariant After this call, Permit2 must expose max allowance and max expiration for the router.
     */
    function _ensurePermit2Max(IERC20 tokenIn, address permit2Address, address universalRouterAddress) internal {
        // Permit2 still needs an ERC20 allowance from the strategy before it can extend allowance to the router.
        uint256 allowance = tokenIn.allowance(address(this), permit2Address);
        if (allowance != type(uint256).max) tokenIn.forceApprove(permit2Address, type(uint256).max);

        IPermit2AllowanceTransfer permit2 = IPermit2AllowanceTransfer(permit2Address);
        (uint160 allowed, uint48 expiration,) =
            permit2.allowance(address(this), address(tokenIn), universalRouterAddress);

        // Keep the Permit2 approval path fully open so repeated background swaps do not need to re-approve every time.
        if (allowed != type(uint160).max || expiration != type(uint48).max) {
            permit2.approve(address(tokenIn), universalRouterAddress, type(uint160).max, type(uint48).max);
        }
    }
}
