// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SFVault} from "contracts/saveFunds/protocol/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/protocol/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/protocol/SFUniswapV3Strategy.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SaveFundHandler is Test {
    using SafeERC20 for IERC20;

    uint16 internal constant MAX_BPS = 10_000;
    uint256 internal constant AMOUNT_IN_BPS_FLAG = 1 << 255;
    uint256 internal constant TARGET_IDLE_BPS = 1500;
    uint256 internal constant IDLE_BAND_BPS = 500;
    uint256 internal constant MIN_IDLE_FLOOR = 50_000e6;
    uint256 internal constant INVEST_IDLE_PCT = 70;

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

    address internal poolToken0;
    address internal poolToken1;

    IERC20 internal underlying;
    IERC20 internal other;

    // ========= scenario params =========
    int24 public rebalanceHalfRangeTicks;

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

    constructor() {}

    function configureProtocol(SFVault _vault, SFStrategyAggregator _aggregator, SFUniswapV3Strategy _uniV3) external {
        vault = _vault;
        aggregator = _aggregator;
        uniV3 = _uniV3;

        underlying = IERC20(vault.asset());
        other = uniV3.otherToken();

        pool = IUniswapV3Pool(uniV3.pool());
        market = new MarketSwapCaller(address(pool));
        poolToken0 = pool.token0();
        poolToken1 = pool.token1();

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

    function configureScenario(int24 _rebalanceHalfRangeTicks, uint256 _underlyingDust, uint256 _otherDust)
        external
    {
        rebalanceHalfRangeTicks = _rebalanceHalfRangeTicks;
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
        ratioSeed; // reserved entropy
        uint16 ratioBps = 5000;
        uint256 deadline = block.timestamp + bound(deadlineSeed, 1, 1 days);

        // Strategy.deposit swaps amountToSwap = assets * ratioBps / 10_000
        uint256 amountToSwap = (amount * uint256(ratioBps)) / 10_000;

        bytes memory swapToOtherData = (amountToSwap == 0) ? bytes("") : _encodeUniV3SwapToOther(amountToSwap, deadline);

        // V3ActionData encoding:
        // (otherRatioBPS, swapToOtherData, swapToUnderlyingData, pmDeadline, minUnderlying, minOther)
        bytes memory actionData = abi.encode(ratioBps, swapToOtherData, bytes(""), deadline, uint256(0), uint256(0));

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
        deadlineSeed; // reserved entropy

        // Deployed aggregator validates UniV3 withdraw payload; use BPS sentinel swap-back.
        bytes memory swapToUnderlyingData = _encodeUniV3SwapToUnderlyingBps(MAX_BPS);
        bytes memory actionData =
            abi.encode(uint16(0), bytes(""), swapToUnderlyingData, uint256(0), uint256(0), uint256(0));

        (address[] memory strategies, bytes[] memory payloads) = _singleStrategyArrays(actionData);

        vm.prank(keeper);
        (bool ok,) = address(vault)
            .call(
                abi.encodeWithSignature("withdrawFromStrategy(uint256,address[],bytes[])", amount, strategies, payloads)
            );
        ok;

        _afterProtocolOp(amtSeed);
    }

    function keeper_applyBufferPolicy(uint256 seed) external {
        if (!_isConfigured()) return;

        uint256 tvl = vault.totalAssets();
        uint256 idle = vault.idleAssets();
        if (tvl == 0) {
            _afterProtocolOp(seed);
            return;
        }

        uint256 target = (tvl * TARGET_IDLE_BPS) / MAX_BPS;
        if (target < MIN_IDLE_FLOOR) target = MIN_IDLE_FLOOR;
        if (target > tvl) target = tvl;

        uint256 band = (tvl * IDLE_BAND_BPS) / MAX_BPS;
        uint256 upper = target + band;

        if (idle > upper) {
            uint256 investAmt = (idle * INVEST_IDLE_PCT) / 100;
            if (investAmt > idle) investAmt = idle;

            uint16 ratioBps = 5000;
            uint256 amountToSwap = (investAmt * uint256(ratioBps)) / MAX_BPS;
            bytes memory swapToOtherData =
                (amountToSwap == 0) ? bytes("") : _encodeUniV3SwapToOther(amountToSwap, block.timestamp + 30 minutes);
            bytes memory actionData =
                abi.encode(ratioBps, swapToOtherData, bytes(""), block.timestamp + 30 minutes, uint256(0), uint256(0));
            (address[] memory strategies, bytes[] memory payloads) = _singleStrategyArrays(actionData);

            vm.prank(keeper);
            (bool okInvest,) = address(vault).call(
                abi.encodeWithSignature("investIntoStrategy(uint256,address[],bytes[])", investAmt, strategies, payloads)
            );
            okInvest;
            _afterProtocolOp(seed);
            return;
        }

        if (idle < target) {
            uint256 need = target - idle;
            bytes memory swapToUnderlyingData = _encodeUniV3SwapToUnderlyingBps(MAX_BPS);
            bytes memory actionData =
                abi.encode(uint16(0), bytes(""), swapToUnderlyingData, uint256(0), uint256(0), uint256(0));
            (address[] memory strategies, bytes[] memory payloads) = _singleStrategyArrays(actionData);

            vm.prank(keeper);
            (bool okWithdraw,) = address(vault).call(
                abi.encodeWithSignature("withdrawFromStrategy(uint256,address[],bytes[])", need, strategies, payloads)
            );
            okWithdraw;
        }

        _afterProtocolOp(seed);
    }

    function operator_takeFees(uint256 seed) external {
        if (!_isConfigured()) return;

        vm.prank(operator);
        (bool ok,) = address(vault).call(abi.encodeWithSignature("takeFees()"));
        ok;

        _afterProtocolOp(seed);
    }

    function keeper_harvest(
        uint256,
        /*ratioSeed*/
        uint256 deadlineSeed
    )
        external
    {
        if (!_isConfigured()) return;

        // Harvest path: strategy._collectFees() decodes V3ActionData.
        // Keep ratioBps=0 to avoid requiring swapToOtherData.
        uint16 ratioBps = 0;
        uint256 deadline = block.timestamp + bound(deadlineSeed, 1, 1 days);

        uint256 otherBal = other.balanceOf(address(uniV3));
        bytes memory swapToUnderlyingData;

        if (otherBal > 0) {
            uint256 amountIn = otherBal > 1_000e6 ? 1_000e6 : otherBal; // swap up to 1000 USDT
            if (amountIn > 0) swapToUnderlyingData = _encodeUniV3SwapToUnderlying(amountIn, deadline);
        }

        bytes memory data = abi.encode(ratioBps, bytes(""), swapToUnderlyingData, deadline, uint256(0), uint256(0));

        bytes memory encoded = _encodeSingleStrategyPayload(data);

        vm.prank(keeper);
        (bool ok,) = address(aggregator).call(abi.encodeWithSignature("harvest(bytes)", encoded));
        ok;

        _afterProtocolOp(deadlineSeed);
    }

    function keeper_rebalance(uint256 seed) external {
        if (!_isConfigured()) return;

        (, int24 tickNow,,,,,) = pool.slot0();
        int24 spacing = pool.tickSpacing();
        int24 lower = _floorToSpacing(tickNow - rebalanceHalfRangeTicks, spacing);
        int24 upper = _floorToSpacing(tickNow + rebalanceHalfRangeTicks, spacing);
        if (lower >= upper) {
            lower = _floorToSpacing(tickNow - spacing, spacing);
            upper = _floorToSpacing(tickNow + spacing, spacing);
        }

        bytes memory rebalanceData = abi.encode(lower, upper, block.timestamp + 30 minutes, uint256(0), uint256(0));
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

    function _pickMarketAmountIn(address tokenIn, uint256 seed, uint256 i) internal view returns (uint256) {
        uint256 r = uint256(keccak256(abi.encode(seed, i, uint256(0xA11CE))));

        // 500–2000 USDC/USDT
        if (tokenIn == address(underlying) || tokenIn == address(other)) {
            return bound(r, 500e6, 2_000e6);
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

    function _encodeUniV3SwapToOther(uint256 amountIn, uint256 deadline) internal view returns (bytes memory) {
        return _encodeUniV3ExactInSwap(address(underlying), address(other), amountIn, deadline);
    }

    function _encodeUniV3SwapToUnderlying(uint256 amountIn, uint256 deadline) internal view returns (bytes memory) {
        return _encodeUniV3ExactInSwap(address(other), address(underlying), amountIn, deadline);
    }

    function _encodeUniV3SwapToUnderlyingBps(uint16 bps) internal pure returns (bytes memory) {
        uint256 amountIn = AMOUNT_IN_BPS_FLAG | uint256(bps);
        return _encodeRankedSwapData(amountIn, uint256(0));
    }

    function _encodeUniV3ExactInSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 deadline)
        internal
        pure
        returns (bytes memory)
    {
        if (amountIn == 0) return bytes("");
        tokenIn;
        tokenOut;
        return _encodeRankedSwapData(amountIn, deadline);
    }

    function _encodeRankedSwapData(uint256 amountIn, uint256 deadline) internal pure returns (bytes memory) {
        uint8[2] memory routeIds;
        uint256[2] memory amountOutMins;
        routeIds[0] = 1;
        routeIds[1] = 2;
        return abi.encode(amountIn, deadline, uint8(2), routeIds, amountOutMins);
    }

    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 mod = tick % spacing;
        int24 floored = tick - mod;
        if (mod < 0) floored -= spacing;
        return floored;
    }
}

contract MarketSwapCaller {
    using SafeERC20 for IERC20;

    uint160 internal constant MIN_SQRT_RATIO_PLUS_ONE = 4295128739 + 1;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970342 - 1;

    IUniswapV3Pool public immutable pool;

    error MarketSwapCaller__AmountInZero();
    error MarketSwapCaller__NotPool();

    constructor(address _pool) {
        pool = IUniswapV3Pool(_pool);
    }

    function marketSwapExactIn(address payer, bool zeroForOne, uint256 amountIn) external {
        require(amountIn > 0, MarketSwapCaller__AmountInZero());
        uint160 limit = zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE;
        pool.swap(address(this), zeroForOne, int256(amountIn), limit, abi.encode(payer));
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(msg.sender == address(pool), MarketSwapCaller__NotPool());
        address payer = abi.decode(data, (address));

        if (amount0Delta > 0) IERC20(pool.token0()).safeTransferFrom(payer, msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(pool.token1()).safeTransferFrom(payer, msg.sender, uint256(amount1Delta));
    }
}
