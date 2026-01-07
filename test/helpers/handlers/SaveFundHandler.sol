// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/SFUniswapV3Strategy.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

library TransferHelper {
    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, value));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }
}

/// @dev Small helper that can call pool.swap and pays the pool in the callback using transferFrom(payer).
contract MarketSwapCaller {
    uint160 internal constant MIN_SQRT_RATIO_PLUS_ONE = 4295128739 + 1;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970342 - 1;

    IUniswapV3Pool public pool;

    constructor(address _pool) {
        pool = IUniswapV3Pool(_pool);
    }

    function marketSwapExactIn(address payer, bool zeroForOne, uint256 amountIn) external {
        uint160 limit = zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE;
        pool.swap(address(this), zeroForOne, int256(amountIn), limit, abi.encode(payer));
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(msg.sender == address(pool), "NOT_POOL");
        address payer = abi.decode(data, (address));

        if (amount0Delta > 0) {
            TransferHelper.safeTransferFrom(pool.token0(), payer, msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            TransferHelper.safeTransferFrom(pool.token1(), payer, msg.sender, uint256(amount1Delta));
        }
    }
}

/// @notice Handler for simulation-based invariant testing.
contract SaveFundHandler is Test {
    // ========= scenario constants (Arbitrum One) =========
    // WETH/USDC 0.05% pool per scenario doc
    address internal constant POOL_WETH_USDC_500 = 0xC6962004f452bE9203591991D15f6b388e09E8D0;

    // Tokens (Arbitrum One)
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    uint24 internal constant POOL_FEE = 500;

    // ========= protocol refs =========
    SFVault public vault;
    SFStrategyAggregator public aggregator;
    SFUniswapV3Strategy public uniV3;

    // ========= actors =========
    address public backendAdmin;
    address public operator;
    address public keeper;
    address public pauseGuardian;

    // ========= market refs =========
    IUniswapV3Pool public pool;
    MarketSwapCaller public market;

    // cache pool tokens to avoid repeated external calls
    address internal poolToken0;
    address internal poolToken1;

    // token handles
    IERC20 internal underlying;
    IERC20 internal other;

    // ========= scenario params =========
    int24 public initTickLower;
    int24 public initTickUpper;

    address[] public users;
    address[] public swappers;

    uint256 public underlyingDust;
    uint256 public otherDust;

    // ========= counters =========
    uint256 public protocolOps;
    uint256 public marketOps;

    // ========= config flags =========
    bool internal protocolConfigured;
    bool internal actorsConfigured;
    bool internal scenarioConfigured;

    // ------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------

    constructor() {
        pool = IUniswapV3Pool(POOL_WETH_USDC_500);
        market = new MarketSwapCaller(POOL_WETH_USDC_500);

        poolToken0 = pool.token0();
        poolToken1 = pool.token1();

        underlying = IERC20(ARB_USDC);
        other = IERC20(ARB_WETH);
    }

    // ------------------------------------------------------------
    // One-time configuration (called from setUp)
    // ------------------------------------------------------------

    function configureProtocol(SFVault _vault, SFStrategyAggregator _aggregator, SFUniswapV3Strategy _uniV3) external {
        vault = _vault;
        aggregator = _aggregator;
        uniV3 = _uniV3;
        protocolConfigured = true;
    }

    function configureActors(address _operator, address _keeper, address _backendAdmin, address _pauseGuardian)
        external
    {
        operator = _operator;
        keeper = _keeper;
        backendAdmin = _backendAdmin;
        pauseGuardian = _pauseGuardian;
        actorsConfigured = true;
    }

    function configureScenario(int24 _tickLower, int24 _tickUpper, uint256 _underlyingDust, uint256 _otherDust)
        external
    {
        initTickLower = _tickLower;
        initTickUpper = _tickUpper;
        underlyingDust = _underlyingDust;
        otherDust = _otherDust;
        scenarioConfigured = true;
    }

    function setUsers(address[] calldata _users) external {
        delete users;
        uint256 len = _users.length;
        for (uint256 i; i < len;) {
            users.push(_users[i]);
            unchecked {
                ++i;
            }
        }
    }

    function setSwappers(address[] calldata _swappers) external {
        delete swappers;
        uint256 len = _swappers.length;
        for (uint256 i; i < len;) {
            swappers.push(_swappers[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _isConfigured() internal view returns (bool) {
        return protocolConfigured && actorsConfigured && scenarioConfigured && users.length != 0;
    }

    // ------------------------------------------------------------
    // Fuzz actions (protocol side)
    // ------------------------------------------------------------

    function backend_registerMember(uint256 userSeed) external {
        if (!_isConfigured()) return;

        address u = _pickUser(userSeed);
        if (u == address(0)) return;

        vm.prank(backendAdmin);
        vault.registerMember(u);

        _afterProtocolOp(userSeed);
    }

    function user_deposit(uint256 userSeed, uint256 amtSeed) external {
        if (!_isConfigured()) return;

        address u = _pickUser(userSeed);
        if (u == address(0)) return;

        // bounded to avoid extreme growth
        uint256 amount = bound(amtSeed, 1e6, 50_000e6);

        // ensure user has funds
        deal(address(underlying), u, underlying.balanceOf(u) + amount);

        vm.startPrank(u);
        underlying.approve(address(vault), type(uint256).max);
        // If user not registered, deposit reverts; avoid killing invariant run.
        (bool ok,) = address(vault).call(abi.encodeWithSignature("deposit(uint256,address)", amount, u));
        ok;
        vm.stopPrank();

        _afterProtocolOp(amtSeed);
    }

    function user_redeem(uint256 userSeed, uint256 sharesSeed) external {
        if (!_isConfigured()) return;

        address u = _pickUser(userSeed);
        if (u == address(0)) return;

        uint256 bal = vault.balanceOf(u);
        if (bal == 0) {
            _afterProtocolOp(userSeed);
            return;
        }

        uint256 shares = bound(sharesSeed, 1, bal);

        vm.startPrank(u);
        (bool ok,) = address(vault).call(abi.encodeWithSignature("redeem(uint256,address,address)", shares, u, u));
        ok;
        vm.stopPrank();

        _afterProtocolOp(userSeed);
    }

    function keeper_invest(uint256 amtSeed, uint256 ratioSeed, uint256 deadlineSeed) external {
        if (!_isConfigured()) return;

        uint256 idle = underlying.balanceOf(address(vault));
        if (idle < 1e6) {
            _afterProtocolOp(amtSeed);
            return;
        }

        uint256 amount = bound(amtSeed, 1e6, idle);
        uint256 ratioBps = uint256(bound(ratioSeed, 0, 10_000));
        uint256 deadline = block.timestamp + bound(deadlineSeed, 1, 1 days);

        bytes memory swapToOther = _encodeUniV3ExactInSwap(address(underlying), address(other), POOL_FEE, amount);
        bytes memory actionData = abi.encode(ratioBps, swapToOther, bytes(""), deadline, uint256(0), uint256(0));

        (address[] memory strategies, bytes[] memory payloads) = _singleStrategyArrays(actionData);

        vm.prank(keeper);
        (bool ok,) = address(vault)
            .call(
                abi.encodeWithSignature("investIntoStrategy(uint256,address[],bytes[])", amount, strategies, payloads)
            );
        ok;

        _afterProtocolOp(amtSeed);
    }

    function keeper_withdrawFromStrategy(uint256 amtSeed, uint256 deadlineSeed) external {
        if (!_isConfigured()) return;

        uint256 stratAssets = uniV3.totalAssets();
        if (stratAssets < 1e6) {
            _afterProtocolOp(amtSeed);
            return;
        }

        uint256 amount = bound(amtSeed, 1e6, stratAssets);
        uint256 deadline = block.timestamp + bound(deadlineSeed, 1, 1 days);

        // UniV3 withdraw path decodes (pmDeadline, minUnderlying, minOther)
        bytes memory actionData = abi.encode(deadline, uint256(0), uint256(0));

        (address[] memory strategies, bytes[] memory payloads) = _singleStrategyArrays(actionData);

        vm.prank(keeper);
        (bool ok,) = address(vault)
            .call(
                abi.encodeWithSignature("withdrawFromStrategy(uint256,address[],bytes[])", amount, strategies, payloads)
            );
        ok;

        _afterProtocolOp(amtSeed);
    }

    function keeper_harvest(uint256 ratioSeed, uint256 deadlineSeed) external {
        if (!_isConfigured()) return;

        uint256 ratioBps = uint256(bound(ratioSeed, 0, 10_000));
        uint256 deadline = block.timestamp + bound(deadlineSeed, 1, 1 days);

        uint256 otherBal = other.balanceOf(address(uniV3));
        if (otherBal == 0) {
            _afterProtocolOp(ratioSeed);
            return;
        }

        uint256 amountIn = otherBal > 1e6 ? 1e6 : otherBal;

        bytes memory swapToUnderlying =
            _encodeUniV3ExactInSwap(address(other), address(underlying), uint24(100), amountIn);

        bytes memory data = abi.encode(ratioBps, swapToUnderlying, bytes(""), deadline, uint256(0), uint256(0));

        bytes memory encoded = _encodeSingleStrategyPayload(data);

        vm.prank(keeper);
        (bool ok,) = address(aggregator).call(abi.encodeWithSignature("harvest(bytes)", encoded));
        ok;

        _afterProtocolOp(ratioSeed);
    }

    function keeper_rebalance(uint256 seed) external {
        if (!_isConfigured()) return;

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory rebalanceData = abi.encode(initTickLower, initTickUpper, deadline, uint256(0), uint256(0));
        bytes memory encoded = _encodeSingleStrategyPayload(rebalanceData);

        vm.prank(keeper);
        (bool ok,) = address(aggregator).call(abi.encodeWithSignature("rebalance(bytes)", encoded));
        ok;

        _afterProtocolOp(seed);
    }

    function pauser_togglePause(uint256 seed) external {
        if (!_isConfigured()) return;

        bool paused;
        (bool okPaused, bytes memory ret) = address(vault).staticcall(abi.encodeWithSignature("paused()"));
        if (!okPaused || ret.length == 0) {
            _afterProtocolOp(seed);
            return;
        }
        paused = abi.decode(ret, (bool));

        vm.prank(pauseGuardian);
        if (paused) {
            (bool ok1,) = address(vault).call(abi.encodeWithSignature("unpause()"));
            (bool ok2,) = address(uniV3).call(abi.encodeWithSignature("unpause()"));
            (bool ok3,) = address(aggregator).call(abi.encodeWithSignature("unpause()"));
            ok1;
            ok2;
            ok3;
        } else {
            (bool ok1,) = address(vault).call(abi.encodeWithSignature("pause()"));
            (bool ok2,) = address(uniV3).call(abi.encodeWithSignature("pause()"));
            (bool ok3,) = address(aggregator).call(abi.encodeWithSignature("pause()"));
            ok1;
            ok2;
            ok3;
        }

        _afterProtocolOp(seed);
    }

    // attacker tries to move shares (should fail due to non-transferable shares)
    function attacker_tryTransfer(uint256 userSeed, uint256 shareSeed) external {
        if (!_isConfigured()) return;

        address u = _pickUser(userSeed);
        if (u == address(0)) return;

        uint256 bal = vault.balanceOf(u);
        if (bal == 0) {
            _afterProtocolOp(shareSeed);
            return;
        }

        uint256 shares = bound(shareSeed, 1, bal);
        address attacker = makeAddr("attacker");

        vm.prank(u);
        // Use low-level call so reverts don't fail the invariant run.
        (bool ok,) = address(vault).call(abi.encodeWithSignature("transfer(address,uint256)", attacker, shares));
        ok;

        _afterProtocolOp(shareSeed);
    }

    function attacker_tryTransferFrom(uint256 userSeed, uint256 shareSeed) external {
        if (!_isConfigured()) return;

        address u = _pickUser(userSeed);
        if (u == address(0)) return;

        uint256 bal = vault.balanceOf(u);
        if (bal == 0) {
            _afterProtocolOp(shareSeed);
            return;
        }

        uint256 shares = bound(shareSeed, 1, bal);
        address attacker = makeAddr("attacker2");

        vm.startPrank(u);
        (bool okApprove,) =
            address(vault).call(abi.encodeWithSignature("approve(address,uint256)", address(this), shares));
        vm.stopPrank();

        if (!okApprove) {
            _afterProtocolOp(shareSeed);
            return;
        }

        // If transferFrom is blocked, it should revert; ignore.
        (bool okTf,) =
            address(vault).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", u, attacker, shares));
        okTf;

        _afterProtocolOp(shareSeed);
    }

    // ------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------

    function _afterProtocolOp(uint256 seed) internal {
        protocolOps++;
        _simulateMarket(seed, 5);
    }

    function _simulateMarket(uint256 seed, uint256 n) internal {
        uint256 len = swappers.length;
        if (len == 0) return;

        for (uint256 i; i < n;) {
            _oneMarketSwap(seed, i, len);
            unchecked {
                ++i;
            }
        }
    }

    function _oneMarketSwap(uint256 seed, uint256 i, uint256 len) internal {
        address swapper = _pickSwapper(seed, i, len);
        if (swapper == address(0)) return;

        bool zeroForOne = _pickDirection(seed, i);

        address tokenIn = zeroForOne ? poolToken0 : poolToken1;
        uint256 amountIn = _pickMarketAmountIn(tokenIn, seed, i);

        // fund swapper and approve MarketSwapCaller to pull in callback
        _dealPlus(tokenIn, swapper, amountIn);
        vm.prank(swapper);
        // approve pool token to be pulled by the callback via transferFrom
        // Note: MarketSwapCaller uses transferFrom(payer, pool, amountDelta), so payer must approve MarketSwapCaller.
        (bool okApprove,) =
            tokenIn.call(abi.encodeWithSignature("approve(address,uint256)", address(market), type(uint256).max));
        okApprove;

        vm.prank(swapper);
        (bool ok,) = address(market)
            .call(abi.encodeWithSignature("marketSwapExactIn(address,bool,uint256)", swapper, zeroForOne, amountIn));
        ok;

        marketOps++;
    }

    function _pickUser(uint256 seed) internal view returns (address) {
        uint256 len = users.length;
        if (len == 0) return address(0);
        return users[seed % len];
    }

    function _pickSwapper(uint256 seed, uint256 i, uint256 len) internal view returns (address) {
        if (len == 0) return address(0);
        uint256 r = uint256(keccak256(abi.encode(seed, i)));
        return swappers[r % len];
    }

    function _pickDirection(uint256 seed, uint256 i) internal pure returns (bool) {
        uint256 r = uint256(keccak256(abi.encode(seed, i, uint256(0xD1))));
        return (r & 1) == 0;
    }

    function _pickMarketAmountIn(address tokenIn, uint256 seed, uint256 i) internal pure returns (uint256) {
        uint256 r = uint256(keccak256(abi.encode(seed, i, uint256(0xA11CE))));

        // Scenario-ish ranges:
        // - USDC: 500–2000 USDC (6 decimals)
        // - WETH: 0.25–1 WETH (18 decimals)
        if (tokenIn == ARB_USDC) {
            return bound(r, 500e6, 2_000e6);
        }
        if (tokenIn == ARB_WETH) {
            return bound(r, 0.25 ether, 1 ether);
        }

        return bound(r, 1, 1e18);
    }

    function _dealPlus(address token, address to, uint256 amount) internal {
        uint256 cur = IERC20(token).balanceOf(to);
        deal(token, to, cur + amount);
    }

    function _singleStrategyArrays(bytes memory payload)
        internal
        view
        returns (address[] memory strategies, bytes[] memory payloads)
    {
        strategies = new address[](1);
        payloads = new bytes[](1);
        strategies[0] = address(uniV3);
        payloads[0] = payload;
    }

    function _encodeSingleStrategyPayload(bytes memory payload) internal view returns (bytes memory) {
        (address[] memory strategies, bytes[] memory payloads) = _singleStrategyArrays(payload);
        return abi.encode(strategies, payloads);
    }

    function _encodeUniV3ExactInSwap(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(tokenIn, tokenOut, fee, amountIn);
    }
}
