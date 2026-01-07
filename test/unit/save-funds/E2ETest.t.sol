// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {DeploySFStrategyAggregator} from "test/utils/06-DeploySFStrategyAggregator.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/SFUniswapV3Strategy.sol";
import {UniswapV3MathHelper} from "contracts/helpers/uniswapHelpers/UniswapV3MathHelper.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

contract E2ETest is Test {
    uint256 internal constant FORK_BLOCK = 418613000;

    // ===== Arbitrum One / Scenario constants =====
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    // WETH/USDC 0.05% pool
    address internal constant POOL_WETH_USDC_500 = 0xC6962004f452bE9203591991D15f6b388e09E8D0;

    // Uniswap V3 periphery on Arbitrum
    address internal constant UNIV3_NONFUNGIBLE_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    // Universal Router on Arbitrum
    address internal constant UNI_UNIVERSAL_ROUTER = 0x4C60051384bd2d3C01bfc845Cf5F4b44bcbE9de5;

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
    uint256 internal constant DUST_USDC = 100;
    uint256 internal constant DUST_WETH = 1;

    // ===== deploy helpers =====
    DeployManagers internal managersDeployer;
    AddAddressesAndRoles internal addressesAndRoles;
    DeploySFStrategyAggregator internal aggregatorDeployer;

    AddressManager internal addrMgr;
    ModuleManager internal modMgr;

    SFVault internal vault;
    SFStrategyAggregator internal aggregator;
    SFUniswapV3Strategy internal uniV3;
    UniswapV3MathHelper internal mathHelper;

    IERC20 internal usdc = IERC20(ARB_USDC);
    IERC20 internal weth = IERC20(ARB_WETH);

    address internal operator;
    address internal backendAdmin;
    address internal keeper = makeAddr("keeper");
    address internal pauseGuardian = makeAddr("pauseGuardian");
    address internal feeReceiver = makeAddr("feeReceiver");

    address[] internal users;
    address[] internal swappers;

    MarketSwapCaller internal market;

    function setUp() public {
        // ===== fork =====
        uint256 forkId = vm.createFork(vm.envString("ARBITRUM_MAINNET_RPC_URL"), FORK_BLOCK);
        vm.selectFork(forkId);

        // ===== deploy managers + base roles/addresses =====
        managersDeployer = new DeployManagers();
        addressesAndRoles = new AddAddressesAndRoles();
        aggregatorDeployer = new DeploySFStrategyAggregator();

        (HelperConfig.NetworkConfig memory config, AddressManager _addrMgr, ModuleManager _modMgr) =
            managersDeployer.run();

        addrMgr = _addrMgr;
        modMgr = _modMgr;

        (operator,,, backendAdmin,,,) = addressesAndRoles.run(addrMgr, config, address(modMgr));

        vm.startPrank(addrMgr.owner());

        // PAUSE_GUARDIAN
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauseGuardian);

        // KEEPER
        addrMgr.createNewRole(Roles.KEEPER);
        addrMgr.proposeRoleHolder(Roles.KEEPER, keeper);

        // fee receiver
        addrMgr.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", feeReceiver, ProtocolAddressType.Admin);
        vm.stopPrank();

        vm.prank(pauseGuardian);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);

        vm.prank(keeper);
        addrMgr.acceptProposedRole(Roles.KEEPER);

        // ===== deploy vault =====
        vault = SFVault(
            UnsafeUpgrades.deployUUPSProxy(
                address(new SFVault()),
                abi.encodeCall(SFVault.initialize, (addrMgr, usdc, "Takasure Save Fund Vault", "TSF"))
            )
        );

        // ===== deploy aggregator =====
        aggregator = aggregatorDeployer.run(IAddressManager(address(addrMgr)), usdc, address(vault));

        vm.startPrank(addrMgr.owner());
        addrMgr.addProtocolAddress("PROTOCOL__SF_VAULT", address(vault), ProtocolAddressType.Protocol);
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(aggregator), ProtocolAddressType.Protocol);
        vm.stopPrank();

        // ===== wire vault + whitelist other token =====
        vm.startPrank(operator);
        vault.setAggregator(ISFStrategy(address(aggregator)));
        vault.whitelistToken(address(weth));

        // set fees (perf 10%) and management fee 0 for scenario-style takeFees cadence
        vault.setFeeConfig(0, 1000, 0);
        vm.stopPrank();

        // ===== deploy math helper + UniV3 strategy =====
        mathHelper = new UniswapV3MathHelper();

        // use a high maxTVL for scenario runs
        uint256 strategyMaxTVL = 100_000_000e6;

        // initial ticks
        int24 initLower = -200;
        int24 initUpper = 200;

        uniV3 = SFUniswapV3Strategy(
            UnsafeUpgrades.deployUUPSProxy(
                address(new SFUniswapV3Strategy()),
                abi.encodeCall(
                    SFUniswapV3Strategy.initialize,
                    (
                        addrMgr,
                        address(vault),
                        usdc,
                        weth,
                        POOL_WETH_USDC_500,
                        UNIV3_NONFUNGIBLE_POSITION_MANAGER,
                        address(mathHelper),
                        strategyMaxTVL,
                        UNI_UNIVERSAL_ROUTER,
                        initLower,
                        initUpper
                    )
                )
            )
        );

        // ===== add strategy to aggregator =====
        vm.prank(operator);
        aggregator.addSubStrategy(address(uniV3), 10_000);

        // ===== allow strategy to manage V3 position NFTs held by vault =====
        vm.prank(operator);
        vault.setERC721ApprovalForAll(UNIV3_NONFUNGIBLE_POSITION_MANAGER, address(uniV3), true);

        // ===== market swap helper =====
        market = new MarketSwapCaller(POOL_WETH_USDC_500);

        // ===== actors =====
        _createActors();
        _registerAllUsers();
        _approveAll();

        // sanity: strategy should start with no router approvals
        _assertNoStaleRouterApprovals();
    }

    function test_SaveFundScenarioSimulation_168Ticks() public {
        uint256 seed = uint256(keccak256(abi.encodePacked("SF_SCENARIO_SEED", block.timestamp)));

        uint256 t0 = block.timestamp;

        for (uint256 tick; tick < N_TICKS; ++tick) {
            // advance time by 1 hour per tick
            vm.warp(t0 + (tick * 1 hours));

            // baseline swaps
            seed = _doRandomMarketSwaps(BASELINE_SWAPS_PER_TICK, seed);

            // sample count of protocol actions for this tick (Poisson-ish lambda~3)
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

    // =============================================================
    //                     Protocol action helpers
    // =============================================================

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

    /// @dev returns true if a withdrawal happened
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
        (, int24 tickNow,,,,,) = IUniswapV3Pool(POOL_WETH_USDC_500).slot0();
        int24 spacing = IUniswapV3Pool(POOL_WETH_USDC_500).tickSpacing();

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

    // =============================================================
    //                     Strategy payload builders
    // =============================================================

    function _buildDepositActionData(uint256 assets) internal view returns (bytes memory) {
        // 50/50 into otherToken by default
        uint16 ratioBps = 5000;
        uint256 amountIn = (assets * ratioBps) / 10_000;

        bytes memory path = abi.encodePacked(ARB_USDC, uint24(500), ARB_WETH);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(uniV3), amountIn, uint256(0), path, true);

        bytes memory swapToOtherData = abi.encode(inputs, block.timestamp + 30 minutes);

        // (otherRatioBPS, swapToOtherData, swapToUnderlyingData, pmDeadline, minUnderlying, minOther)
        return abi.encode(ratioBps, swapToOtherData, bytes(""), block.timestamp + 30 minutes, 0, 0);
    }

    function _buildWithdrawActionData() internal view returns (bytes memory) {
        // no swap-back payload (strategy will sweep both tokens to vault)
        return abi.encode(uint16(0), bytes(""), bytes(""), block.timestamp + 30 minutes, 0, 0);
    }

    // =============================================================
    //                     Market swaps simulation
    // =============================================================

    function _doRandomMarketSwaps(uint256 n, uint256 seed) internal returns (uint256) {
        for (uint256 i; i < n; ++i) {
            uint256 si;
            (seed, si) = _randBound(seed, swappers.length);
            address s = swappers[si];

            uint256 dir;
            (seed, dir) = _randBound(seed, 2);

            if (dir == 0) {
                // USDC -> WETH amount range 500..2000 USDC
                uint256 amt;
                (seed, amt) = _randRange(seed, 500e6, 2000e6);
                vm.prank(s);
                market.swapExactInput(ARB_USDC, ARB_WETH, amt);
            } else {
                // WETH -> USDC amount range 0.25..1 WETH
                uint256 amtW;
                (seed, amtW) = _randRange(seed, 0.25 ether, 1 ether);
                vm.prank(s);
                market.swapExactInput(ARB_WETH, ARB_USDC, amtW);
            }

            seed = _next(seed);
        }
        return seed;
    }

    // =============================================================
    //                         Assertions
    // =============================================================

    function _assertTotalSupplyEqualsSumUserBalances() internal view {
        uint256 sum;
        for (uint256 i; i < users.length; ++i) {
            sum += vault.balanceOf(users[i]);
        }
        assertEq(vault.totalSupply(), sum, "share supply mismatch");
    }

    function _assertStrategyHoldsNoTokens() internal view {
        assertLe(usdc.balanceOf(address(uniV3)), DUST_USDC, "uniV3 holds too much USDC");
        assertLe(weth.balanceOf(address(uniV3)), DUST_WETH, "uniV3 holds too much WETH");
    }

    function _assertNoStaleRouterApprovals() internal view {
        assertEq(usdc.allowance(address(uniV3), UNI_UNIVERSAL_ROUTER), 0, "USDC router allowance not cleared");
        assertEq(weth.allowance(address(uniV3), UNI_UNIVERSAL_ROUTER), 0, "WETH router allowance not cleared");
    }

    // =============================================================
    //                        Setup helpers
    // =============================================================

    function _createActors() internal {
        users = new address[](NUM_USERS);
        swappers = new address[](NUM_SWAPPERS);

        for (uint256 i; i < NUM_USERS; ++i) {
            address u = makeAddr(string.concat("user", vm.toString(i)));
            users[i] = u;

            // fund user with USDC for deposits
            deal(ARB_USDC, u, 1_000_000e6);
        }

        for (uint256 j; j < NUM_SWAPPERS; ++j) {
            address s = makeAddr(string.concat("swapper", vm.toString(j)));
            swappers[j] = s;

            // fund swappers with both sides of the pool
            deal(ARB_USDC, s, 5_000_000e6);
            deal(ARB_WETH, s, 2_000 ether);
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
            weth.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
    }

    // =============================================================
    //                     Randomness / sampling
    // =============================================================

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

    /// @dev Discrete sampler approximating Poisson(lambda=3) with CDF thresholds (scaled 1e6)
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
        // for negative ticks, mod is negative in Solidity; adjust toward -infinity
        if (mod < 0) floored -= spacing;
        return floored;
    }
}

// =============================================================
//                       Minimal UniV3 swapper
// =============================================================

contract MarketSwapCaller is IUniswapV3SwapCallback {
    address public immutable pool;

    // Uniswap V3 sqrt ratio bounds
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
