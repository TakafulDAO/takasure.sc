// SPDX-License-Identifier: GPL-3.0

/*
Detailed explanation of the flow tested here

This test forks Arbitrum One at a fixed mainnet block (after first investment) and reuses deployed
Save Funds contracts loaded from deployments/mainnet_arbitrum_one.

Flow:
1. Load deployed AddressManager, SFVault, SFStrategyAggregator, and SFUniswapV3Strategy.
2. Resolve live role holders (operator/keeper/backend admin/pause guardian) and unpause if needed.
3. Create simulated users and market swappers, register users in the deployed vault, and approve token spending.
4. Run a 168-tick (hourly) simulation loop with randomized deposits/withdrawals plus baseline/noise market swaps.
5. Apply keeper policy to invest or withdraw strategy liquidity based on idle-vs-target buffer.
6. Execute maintenance cadence: harvest, takeFees, and periodic rebalance around current pool tick.
7. Assert supply/accounting and approval invariants at each tick, then perform end-of-run solvency checks.
*/
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {SFVault} from "contracts/saveFunds/protocol/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/protocol/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/protocol/SFUniswapV3Strategy.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract E2ETest is Test {
    uint256 internal constant FORK_BLOCK = 430826360;
    uint16 internal constant MAX_BPS = 10_000;
    uint256 internal constant AMOUNT_IN_BPS_FLAG = 1 << 255;
    uint24 internal constant SWAP_V4_POOL_FEE = 8;
    int24 internal constant SWAP_V4_POOL_TICK_SPACING = 1;
    address internal constant SWAP_V4_POOL_HOOKS = address(0);

    // Universal Router on Arbitrum One (current deployment config)
    address internal constant UNI_UNIVERSAL_ROUTER = 0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3;

    // Simulation params
    uint256 internal constant N_TICKS = 168; // 7 days * 24 hours
    uint256 internal constant NUM_USERS = 100;
    uint256 internal constant NUM_SWAPPERS = 150;

    uint256 internal constant BASELINE_SWAPS_PER_TICK = 20;
    uint256 internal constant SWAPS_PER_PROTOCOL_ACTION = 10;

    // action split: deposit 45%, withdraw 45%, noop 10%
    uint256 internal constant P_DEPOSIT = 45;
    uint256 internal constant P_WITHDRAW = 45;
    // noop = 10%

    // deposit amount range: 100..10,000 USDC
    uint256 internal constant MIN_DEPOSIT = 100e6;
    uint256 internal constant MAX_DEPOSIT = 10_000e6;

    // withdrawal fraction range: 5%..60% of user’s redeemable
    uint256 internal constant MIN_WITHDRAW_PCT = 5;
    uint256 internal constant MAX_WITHDRAW_PCT = 60;

    // buffer policy
    uint256 internal constant TARGET_IDLE_BPS = 1500; // 15%
    uint256 internal constant IDLE_BAND_BPS = 500; // +/- 5% TVL band for invest trigger
    uint256 internal constant MIN_IDLE_FLOOR = 50_000e6;
    uint256 internal constant INVEST_IDLE_PCT = 70; // invest 70% of current idle (when above upper band)

    // cadence
    uint256 internal constant HARVEST_EVERY_TICKS = 6;
    uint256 internal constant REBALANCE_EVERY_TICKS = 24;
    uint256 internal constant TAKE_FEES_EVERY_TICKS = 24;

    // rebalance range half-width in ticks (rounded to tickSpacing)
    int24 internal constant HALF_RANGE_TICKS = 1200;

    // dust thresholds
    uint256 internal constant DUST_USDC = 10_000; // 0.01 USDC
    uint256 internal constant DUST_USDT = 10_000; // 0.01 USDT

    AddressManager internal addrMgr;
    AddressGetter internal addrGetter;

    SFVault internal vault;
    SFStrategyAggregator internal aggregator;
    SFUniswapV3Strategy internal uniV3;

    IERC20 internal usdc;
    IERC20 internal usdt;

    address internal POOL_USDC_USDT;
    uint256 internal initialTotalSupply;
    uint256 internal initialStrategyUsdc;
    uint256 internal initialStrategyUsdt;

    address internal operator;
    address internal backendAdmin;
    address internal keeper;
    address internal pauseGuardian;

    address[] internal users;
    address[] internal swappers;

    MarketSwapCaller internal market;

    function setUp() public {
        uint256 forkId = vm.createFork(vm.envString("ARBITRUM_MAINNET_RPC_URL"), FORK_BLOCK);
        vm.selectFork(forkId);

        addrGetter = new AddressGetter();
        addrMgr = AddressManager(_getAddr("AddressManager"));
        vault = SFVault(_getAddr("SFVault"));
        aggregator = SFStrategyAggregator(_getAddr("SFStrategyAggregator"));
        uniV3 = SFUniswapV3Strategy(_getAddr("SFUniswapV3Strategy"));

        operator = addrMgr.currentRoleHolders(Roles.OPERATOR);
        backendAdmin = addrMgr.currentRoleHolders(Roles.BACKEND_ADMIN);
        keeper = addrMgr.currentRoleHolders(Roles.KEEPER);
        pauseGuardian = addrMgr.currentRoleHolders(Roles.PAUSE_GUARDIAN);
        if (keeper == address(0)) keeper = operator;

        require(operator != address(0) && addrMgr.hasRole(Roles.OPERATOR, operator), "operator missing");
        require(
            backendAdmin != address(0) && addrMgr.hasRole(Roles.BACKEND_ADMIN, backendAdmin), "backend admin missing"
        );
        require(keeper != address(0) && addrMgr.hasRole(Roles.KEEPER, keeper), "keeper missing");

        _upgradeSaveFundsImplementations();

        if (pauseGuardian != address(0) && addrMgr.hasRole(Roles.PAUSE_GUARDIAN, pauseGuardian)) {
            if (vault.paused()) {
                vm.prank(pauseGuardian);
                vault.unpause();
            }
            if (aggregator.paused()) {
                vm.prank(pauseGuardian);
                aggregator.unpause();
            }
            if (uniV3.paused()) {
                vm.prank(pauseGuardian);
                uniV3.unpause();
            }
        }

        // Ensure deployed addresses are wired as expected in AddressManager.
        assertEq(addrMgr.getProtocolAddressByName("PROTOCOL__SF_VAULT").addr, address(vault));
        assertEq(addrMgr.getProtocolAddressByName("PROTOCOL__SF_AGGREGATOR").addr, address(aggregator));

        usdc = IERC20(vault.asset());
        usdt = uniV3.otherToken();
        POOL_USDC_USDT = address(uniV3.pool());
        require(POOL_USDC_USDT != address(0), "pool missing");

        // ===== market swap helper =====
        market = new MarketSwapCaller(POOL_USDC_USDT);

        // ===== actors =====
        _createActors();
        _registerAllUsers();
        _approveAll();
        initialTotalSupply = vault.totalSupply();
        initialStrategyUsdc = usdc.balanceOf(address(uniV3));
        initialStrategyUsdt = usdt.balanceOf(address(uniV3));

        _assertNoStaleRouterApprovals();
    }

    function _upgradeSaveFundsImplementations() internal {
        vm.startPrank(operator);
        Upgrades.upgradeProxy(address(aggregator), "SFStrategyAggregator.sol", "");
        Upgrades.upgradeProxy(address(uniV3), "SFUniswapV3Strategy.sol", "");
        uniV3.setSwapV4PoolConfig(SWAP_V4_POOL_FEE, SWAP_V4_POOL_TICK_SPACING, SWAP_V4_POOL_HOOKS);
        vm.stopPrank();
    }

    function test_SaveFundScenarioSimulation_168Ticks() public {
        uint256 seed = uint256(keccak256(abi.encodePacked("SF_SCENARIO_SEED", block.timestamp)));

        uint256 t0 = block.timestamp;

        for (uint256 tick; tick < N_TICKS; ++tick) {
            // advance time by 1 hour per tick
            vm.warp(t0 + (tick * 1 hours));

            // baseline swaps
            seed = _doRandomMarketSwaps(BASELINE_SWAPS_PER_TICK, seed);

            uint256 nActions;
            (seed, nActions) = _samplePoissonLambda3(seed);

            bool hadWithdrawals = false;

            for (uint256 a; a < nActions; ++a) {
                uint256 rollPct;
                (seed, rollPct) = _randBound(seed, 100);

                if (rollPct < P_DEPOSIT) {
                    seed = _protocolDeposit(seed);
                } else if (rollPct < (P_DEPOSIT + P_WITHDRAW)) {
                    bool did = _protocolWithdraw(seed);
                    // update seed again (withdraw uses randomness internally too)
                    seed = _next(seed);
                    if (did) hadWithdrawals = true;
                } else {
                    // noop
                    seed = _next(seed);
                }

                // post-action swaps (arbitrage / noise)
                seed = _doRandomMarketSwaps(SWAPS_PER_PROTOCOL_ACTION, seed);
            }

            // keeper buffer policy AFTER user actions/swaps
            seed = _applyBufferPolicy(seed, hadWithdrawals);

            // cadence: harvest every 6 ticks
            if ((tick + 1) % HARVEST_EVERY_TICKS == 0) {
                vm.prank(keeper);
                // harvest all strategies with empty per-strategy payloads
                aggregator.harvest(bytes(""));
            }

            // cadence: daily takeFees after harvest
            if ((tick + 1) % TAKE_FEES_EVERY_TICKS == 0) {
                vm.prank(operator);
                vault.takeFees();
            }

            // cadence: rebalance every 24 ticks (after swaps)
            if ((tick + 1) % REBALANCE_EVERY_TICKS == 0) {
                _keeperRebalanceToCurrentTickRange();
            }

            // tick-level assertions
            _assertTotalSupplyEqualsSumUserBalances();
            _assertStrategyHoldsNoTokens();
            _assertNoStaleRouterApprovals();
        }

        // end-of-run: basic solvency-ish check (sum of claimable <= reported TVL, allow rounding slack)
        uint256 sumClaimable;
        for (uint256 i; i < users.length; ++i) {
            uint256 sh = vault.balanceOf(users[i]);
            if (sh == 0) continue;
            sumClaimable += vault.previewRedeem(sh);
        }
        assertLe(sumClaimable, vault.totalAssets() + 10, "sum claimable > totalAssets (rounding?)");
    }

    // Helpers

    function _protocolDeposit(uint256 seed) internal returns (uint256) {
        uint256 ui;
        (seed, ui) = _randBound(seed, users.length);
        address u = users[ui];

        uint256 amtRaw;
        (seed, amtRaw) = _randRange(seed, MIN_DEPOSIT, MAX_DEPOSIT);
        uint256 maxDep = vault.maxDeposit(u);
        uint256 bal = usdc.balanceOf(u);

        uint256 amt = amtRaw;
        if (amt > maxDep) amt = maxDep;
        if (amt > bal) amt = bal;

        if (amt < 1e6) return _next(seed); // skip tiny/zero deposits

        vm.prank(u);
        vault.deposit(amt, u);

        return _next(seed);
    }

    function _protocolWithdraw(uint256 seed) internal returns (bool) {
        uint256 ui;
        (seed, ui) = _randBound(seed, users.length);
        address u = users[ui];

        uint256 sh = vault.balanceOf(u);
        if (sh == 0) return false;

        uint256 idle = vault.idleAssets();
        if (idle == 0) return false;

        // user redeemable (based on totalAssets), but we must cap to idle to avoid reverting
        uint256 userAssets = vault.previewRedeem(sh);

        uint256 pct;
        (seed, pct) = _randRange(seed, MIN_WITHDRAW_PCT, MAX_WITHDRAW_PCT);
        uint256 desired = (userAssets * pct) / 100;

        uint256 assetsToWithdraw = desired;
        if (assetsToWithdraw > idle) assetsToWithdraw = idle;
        if (assetsToWithdraw > userAssets) assetsToWithdraw = userAssets;

        if (assetsToWithdraw < 1e6) return false;

        vm.prank(u);
        vault.withdraw(assetsToWithdraw, u, u);
        return true;
    }

    function _applyBufferPolicy(uint256 seed, bool hadWithdrawals) internal returns (uint256) {
        uint256 tvl = vault.totalAssets();
        uint256 idle = vault.idleAssets();

        if (tvl == 0) return _next(seed);

        // target = max(15% TVL, 50k), but never exceed TVL
        uint256 target = (tvl * TARGET_IDLE_BPS) / 10_000;
        if (target < MIN_IDLE_FLOOR) target = MIN_IDLE_FLOOR;
        if (target > tvl) target = tvl;

        uint256 band = (tvl * IDLE_BAND_BPS) / 10_000;
        uint256 upper = target + band;

        // invest if idle > upper band
        if (idle > upper) {
            uint256 investAmt = (idle * INVEST_IDLE_PCT) / 100;
            if (investAmt > idle) investAmt = idle;

            // build per-strategy data
            bytes memory stratPayload = _buildDepositActionData(investAmt);
            address[] memory strats = new address[](1);
            bytes[] memory payloads = new bytes[](1);
            strats[0] = address(uniV3);
            payloads[0] = stratPayload;

            vm.prank(keeper);
            vault.investIntoStrategy(investAmt, strats, payloads);

            return _next(seed);
        }

        // withdraw from strategy if idle < target AND withdrawals happened this tick
        if (hadWithdrawals && idle < target) {
            uint256 need = target - idle;

            bytes memory stratPayload = _buildWithdrawActionData();
            address[] memory strats = new address[](1);
            bytes[] memory payloads = new bytes[](1);
            strats[0] = address(uniV3);
            payloads[0] = stratPayload;

            vm.prank(keeper);
            vault.withdrawFromStrategy(need, strats, payloads);

            return _next(seed);
        }

        return _next(seed);
    }

    function _keeperRebalanceToCurrentTickRange() internal {
        // read current tick
        (, int24 tickNow,,,,,) = IUniswapV3Pool(POOL_USDC_USDT).slot0();
        int24 spacing = IUniswapV3Pool(POOL_USDC_USDT).tickSpacing();

        int24 lower = _floorToSpacing(tickNow - HALF_RANGE_TICKS, spacing);
        int24 upper = _floorToSpacing(tickNow + HALF_RANGE_TICKS, spacing);
        if (lower >= upper) {
            // fallback to a minimal valid range
            lower = _floorToSpacing(tickNow - spacing, spacing);
            upper = _floorToSpacing(tickNow + spacing, spacing);
        }

        bytes memory payload = abi.encode(lower, upper, block.timestamp + 30 minutes, 0, 0);

        address[] memory strats = new address[](1);
        bytes[] memory payloads = new bytes[](1);
        strats[0] = address(uniV3);
        payloads[0] = payload;

        vm.prank(keeper);
        aggregator.rebalance(abi.encode(strats, payloads));
    }

    // Strategy payload

    function _buildDepositActionData(uint256 assets) internal view returns (bytes memory) {
        // 50/50 into otherToken by default
        uint16 ratioBps = 5000;
        uint256 amountIn = (assets * ratioBps) / 10_000;
        bytes memory swapToOtherData = abi.encode(amountIn, uint256(0), block.timestamp + 30 minutes);

        // (otherRatioBPS, swapToOtherData, swapToUnderlyingData, pmDeadline, minUnderlying, minOther)
        return abi.encode(ratioBps, swapToOtherData, bytes(""), block.timestamp + 30 minutes, 0, 0);
    }

    function _buildWithdrawActionData() internal view returns (bytes memory) {
        bytes memory swapToUnderlyingData = _encodeSwapDataExactInBps(address(usdt), address(usdc), MAX_BPS);
        return abi.encode(uint16(0), bytes(""), swapToUnderlyingData, uint256(0), uint256(0), uint256(0));
    }

    function _encodeSwapDataExactInBps(address tokenIn, address tokenOut, uint16 bps)
        internal
        pure
        returns (bytes memory)
    {
        uint256 amountIn = AMOUNT_IN_BPS_FLAG | uint256(bps);
        tokenIn;
        tokenOut;
        return abi.encode(amountIn, uint256(0), uint256(0));
    }

    // Market swaps simulation

    function _doRandomMarketSwaps(uint256 n, uint256 seed) internal returns (uint256) {
        for (uint256 i; i < n; ++i) {
            uint256 si;
            (seed, si) = _randBound(seed, swappers.length);
            address s = swappers[si];

            uint256 dir;
            (seed, dir) = _randBound(seed, 2);

            if (dir == 0) {
                // USDC -> USDT amount range 500..2000 USDC
                uint256 amt;
                (seed, amt) = _randRange(seed, 500e6, 2000e6);
                vm.prank(s);
                market.swapExactInput(address(usdc), address(usdt), amt);
            } else {
                // USDT -> USDC amount range 500..2000 USDT
                uint256 amtT;
                (seed, amtT) = _randRange(seed, 500e6, 2000e6);
                vm.prank(s);
                market.swapExactInput(address(usdt), address(usdc), amtT);
            }

            seed = _next(seed);
        }
        return seed;
    }

    // Assertions

    function _assertTotalSupplyEqualsSumUserBalances() internal view {
        uint256 sum;
        for (uint256 i; i < users.length; ++i) {
            sum += vault.balanceOf(users[i]);
        }
        assertEq(vault.totalSupply(), initialTotalSupply + sum, "share supply mismatch");
    }

    function _assertStrategyHoldsNoTokens() internal view {
        assertLe(usdc.balanceOf(address(uniV3)), initialStrategyUsdc + DUST_USDC, "uniV3 holds too much USDC");
        assertLe(usdt.balanceOf(address(uniV3)), initialStrategyUsdt + DUST_USDT, "uniV3 holds too much USDT");
    }

    function _assertNoStaleRouterApprovals() internal view {
        assertEq(usdc.allowance(address(uniV3), UNI_UNIVERSAL_ROUTER), 0, "USDC router allowance not cleared");
        assertEq(usdt.allowance(address(uniV3), UNI_UNIVERSAL_ROUTER), 0, "USDT router allowance not cleared");
    }

    // Setup helpers

    function _createActors() internal {
        users = new address[](NUM_USERS);
        swappers = new address[](NUM_SWAPPERS);

        for (uint256 i; i < NUM_USERS; ++i) {
            address u = makeAddr(string.concat("user", vm.toString(i)));
            users[i] = u;

            // fund user with USDC for deposits
            deal(address(usdc), u, 1_000_000e6);
        }

        for (uint256 j; j < NUM_SWAPPERS; ++j) {
            address s = makeAddr(string.concat("swapper", vm.toString(j)));
            swappers[j] = s;

            // fund swappers with both sides of the pool
            deal(address(usdc), s, 5_000_000e6);
            deal(address(usdt), s, 5_000_000e6);
        }
    }

    function _registerAllUsers() internal {
        vm.startPrank(backendAdmin);
        for (uint256 i; i < users.length; ++i) {
            vault.registerMember(users[i]);
        }
        vm.stopPrank();
    }

    function _approveAll() internal {
        // users approve vault for USDC
        for (uint256 i; i < users.length; ++i) {
            address u = users[i];
            vm.startPrank(u);
            usdc.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }

        // swappers approve market caller
        for (uint256 j; j < swappers.length; ++j) {
            address s = swappers[j];
            vm.startPrank(s);
            usdc.approve(address(market), type(uint256).max);
            usdt.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _getAddr(string memory contractName) internal view returns (address) {
        return addrGetter.getAddress(block.chainid, contractName);
    }

    function _next(uint256 seed) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(seed)));
    }

    function _randBound(uint256 seed, uint256 maxExclusive) internal pure returns (uint256 newSeed, uint256 r) {
        newSeed = _next(seed);
        r = maxExclusive == 0 ? 0 : (newSeed % maxExclusive);
    }

    function _randRange(uint256 seed, uint256 minIncl, uint256 maxIncl)
        internal
        pure
        returns (uint256 newSeed, uint256 r)
    {
        require(maxIncl >= minIncl, "bad range");
        uint256 span = (maxIncl - minIncl) + 1;
        (newSeed, r) = _randBound(seed, span);
        r = minIncl + r;
    }

    function _samplePoissonLambda3(uint256 seed) internal pure returns (uint256 newSeed, uint256 k) {
        uint256 r;
        (newSeed, r) = _randBound(seed, 1_000_000);

        // CDF (lambda=3) scaled 1e6:
        // k<=0:  49,787
        // k<=1: 199,148
        // k<=2: 423,190
        // k<=3: 647,232
        // k<=4: 815,264
        // k<=5: 916,083
        // k<=6: 966,492
        // k<=7: 988,096
        // k<=8: 996,197
        // k<=9: 998,897
        // k<=10:999,707
        if (r < 49_787) return (newSeed, 0);
        if (r < 199_148) return (newSeed, 1);
        if (r < 423_190) return (newSeed, 2);
        if (r < 647_232) return (newSeed, 3);
        if (r < 815_264) return (newSeed, 4);
        if (r < 916_083) return (newSeed, 5);
        if (r < 966_492) return (newSeed, 6);
        if (r < 988_096) return (newSeed, 7);
        if (r < 996_197) return (newSeed, 8);
        if (r < 998_897) return (newSeed, 9);
        if (r < 999_707) return (newSeed, 10);
        return (newSeed, 11);
    }

    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 mod = tick % spacing;
        int24 floored = tick - mod;
        if (mod < 0) floored -= spacing;
        return floored;
    }
}

contract AddressGetter is GetContractAddress {
    function getAddress(uint256 chainId, string memory contractName) external view returns (address) {
        return _getContractAddress(chainId, contractName);
    }
}

contract MarketSwapCaller is IUniswapV3SwapCallback {
    address public immutable pool;

    uint160 internal constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    constructor(address _pool) {
        pool = _pool;
    }

    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn) external {
        require(amountIn > 0, "amountIn=0");

        // token0 -> token1 when zeroForOne=true
        bool zeroForOne = tokenIn < tokenOut;

        IUniswapV3Pool(pool)
            .swap(
                address(this),
                zeroForOne,
                int256(amountIn),
                zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
                abi.encode(tokenIn, msg.sender) // tokenIn, payer
            );
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        require(msg.sender == pool, "not pool");

        (address tokenIn, address payer) = abi.decode(data, (address, address));

        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        IERC20(tokenIn).transferFrom(payer, msg.sender, amountToPay);
    }
}
