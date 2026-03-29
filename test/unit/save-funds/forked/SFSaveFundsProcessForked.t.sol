// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SFVault} from "contracts/saveFunds/protocol/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/protocol/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/protocol/SFUniswapV3Strategy.sol";
import {SFUniswapV3SwapRouterHelper} from "contracts/helpers/uniswapHelpers/SFUniswapV3SwapRouterHelper.sol";
import {SFVaultLens} from "contracts/saveFunds/lens/SFVaultLens.sol";
import {SFStrategyAggregatorLens} from "contracts/saveFunds/lens/SFStrategyAggregatorLens.sol";
import {SFUniswapV3StrategyLens} from "contracts/saveFunds/lens/SFUniswapV3StrategyLens.sol";
import {SFLens} from "contracts/saveFunds/lens/SFLens.sol";
import {SFTwapValuator} from "contracts/saveFunds/valuator/SFTwapValuator.sol";
import {UniswapV3MathHelper} from "contracts/helpers/uniswapHelpers/UniswapV3MathHelper.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {StrategyConfig, SubStrategy} from "contracts/types/Strategies.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMathV3} from "contracts/helpers/uniswapHelpers/libraries/TickMathV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";

contract SFSaveFundsProcessForkedTest is Test {
    using SafeERC20 for IERC20;

    uint256 internal constant FORK_BLOCK = 430826360;

    // Shared constants and sentinel flag used by the strategy's swap encoding.
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant AMOUNT_IN_BPS_FLAG = 1 << 255;
    string internal constant SWAP_ROUTER_HELPER_NAME = "HELPER__SF_SWAP_ROUTER";
    address internal constant UNI_V3_NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    uint24 internal constant SWAP_V4_POOL_FEE = 8;
    int24 internal constant SWAP_V4_POOL_TICK_SPACING = 1;
    address internal constant SWAP_V4_POOL_HOOKS = address(0);

    AddressGetter internal addrGetter;

    AddressManager internal addrMgr;
    SFVault internal vault;
    SFStrategyAggregator internal aggregator;
    SFUniswapV3Strategy internal uniV3;
    SFVaultLens internal vaultLens;
    SFStrategyAggregatorLens internal aggregatorLens;
    SFUniswapV3StrategyLens internal uniV3Lens;
    SFLens internal sfLens;
    SFTwapValuator internal valuator;
    UniswapV3MathHelper internal mathHelper;

    IERC20 internal asset;
    IERC20 internal other;
    IUniswapV3Pool internal pool;
    UniV3SwapHelper internal swapper;

    address internal operator;
    address internal keeper;
    address internal backendAdmin;
    address internal pauseGuardian;

    address internal alice;
    address internal bob;
    address internal charlie;

    function setUp() public {
        // Fork Arbitrum One to use live deployed contracts and real pool state.
        uint256 forkId = vm.createFork(vm.envString("ARBITRUM_MAINNET_RPC_URL"), FORK_BLOCK);
        vm.selectFork(forkId);

        // Resolve deployment addresses via the helper script.
        addrGetter = new AddressGetter();

        // Load core protocol contracts (already deployed on Arbitrum One).
        addrMgr = AddressManager(_getAddr("AddressManager"));
        vault = SFVault(_getAddr("SFVault"));
        aggregator = SFStrategyAggregator(_getAddr("SFStrategyAggregator"));
        uniV3 = SFUniswapV3Strategy(_getAddr("SFUniswapV3Strategy"));
        vaultLens = SFVaultLens(_getAddr("SFVaultLens"));
        aggregatorLens = SFStrategyAggregatorLens(_getAddr("SFStrategyAggregatorLens"));
        uniV3Lens = SFUniswapV3StrategyLens(_getAddr("SFUniswapV3StrategyLens"));
        sfLens = SFLens(_getAddr("SFLens"));
        valuator = SFTwapValuator(_getAddr("SFTwapValuator"));
        mathHelper = UniswapV3MathHelper(_getAddr("UniswapV3MathHelper"));

        _assertDeployed(address(addrMgr), "AddressManager");
        _assertDeployed(address(vault), "SFVault");
        _assertDeployed(address(aggregator), "SFStrategyAggregator");
        _assertDeployed(address(uniV3), "SFUniswapV3Strategy");
        _assertDeployed(address(vaultLens), "SFVaultLens");
        _assertDeployed(address(aggregatorLens), "SFStrategyAggregatorLens");
        _assertDeployed(address(uniV3Lens), "SFUniswapV3StrategyLens");
        _assertDeployed(address(sfLens), "SFLens");
        _assertDeployed(address(valuator), "SFTwapValuator");
        _assertDeployed(address(mathHelper), "UniswapV3MathHelper");

        // Fetch current role holders from AddressManager.
        operator = addrMgr.currentRoleHolders(Roles.OPERATOR);
        backendAdmin = addrMgr.currentRoleHolders(Roles.BACKEND_ADMIN);
        keeper = addrMgr.currentRoleHolders(Roles.KEEPER);
        pauseGuardian = addrMgr.currentRoleHolders(Roles.PAUSE_GUARDIAN);
        if (keeper == address(0)) keeper = operator;

        require(operator != address(0) && addrMgr.hasRole(Roles.OPERATOR, operator), "operator missing");

        _ensureBackendAdmin();
        _upgradeSaveFundsImplementations();

        // Pull token/pool addresses from protocol contracts.
        asset = IERC20(vault.asset());
        other = IERC20(uniV3.otherToken());
        pool = IUniswapV3Pool(uniV3.pool());
        swapper = new UniV3SwapHelper(address(pool));

        // Sanity check AddressManager points to the same vault/aggregator.
        assertEq(addrMgr.getProtocolAddressByName("PROTOCOL__SF_VAULT").addr, address(vault));
        assertEq(addrMgr.getProtocolAddressByName("PROTOCOL__SF_AGGREGATOR").addr, address(aggregator));

        // Ensure aggregator has the expected strategy wiring.
        _assertStrategyIsConfigured();

        // Remove TVL cap.
        vm.prank(operator);
        vault.setTVLCap(0);

        // Some deployments may be paused; unpause to allow actions in this test.
        _ensureUnpaused();

        // Configure valuator to price the "other" token using the pool if needed.
        if (valuator.valuationPool(address(other)) != address(pool)) {
            vm.prank(operator);
            valuator.setValuationPool(address(other), address(pool));
        }

        // Ensure default withdraw payload exists for the UniV3 strategy.
        _ensureDefaultWithdrawPayload();
        // Register members and fund them for deposits.
        _registerAndFundUsers();
    }

    function _upgradeSaveFundsImplementations() internal {
        address helper = address(new SFUniswapV3SwapRouterHelper(address(addrMgr)));

        _upsertSwapRouterHelper(helper);

        vm.startPrank(operator);
        UnsafeUpgrades.upgradeProxy(address(aggregator), address(new SFStrategyAggregator()), "");
        UnsafeUpgrades.upgradeProxy(address(uniV3), address(new SFUniswapV3Strategy()), "");
        uniV3.setSwapV4PoolConfig(SWAP_V4_POOL_FEE, SWAP_V4_POOL_TICK_SPACING, SWAP_V4_POOL_HOOKS);
        vm.stopPrank();
    }

    function _upsertSwapRouterHelper(address helper) internal {
        address owner = addrMgr.owner();

        vm.prank(owner);
        try addrMgr.updateProtocolAddress(SWAP_ROUTER_HELPER_NAME, helper) {
            return;
        } catch {}

        vm.prank(owner);
        addrMgr.addProtocolAddress(SWAP_ROUTER_HELPER_NAME, helper, ProtocolAddressType.Helper);
    }

    function testForked_SaveFundsProcess_MultiUser() public {
        console2.log("Starting end-to-end save funds process test on forked Arbitrum One...");
        // End-to-end scenario:
        // deposit -> invest -> lens checks -> time + swaps -> harvest -> rebalance -> withdraw -> final checks.
        _depositUsers();
        _investHalfIdle();
        _assertLensState();
        _harvestAndRebalance();
        _withdrawFromStrategyAndUser();
        _finalAssertions();
        console2.log("Test completed successfully.");
    }

    function _getAddr(string memory contractName) internal view returns (address) {
        // Read deployed address from deployments JSON for the current chain.
        return addrGetter.getAddress(block.chainid, contractName);
    }

    function _assertDeployed(address target, string memory name) internal view {
        // Ensure address is non-zero and has bytecode.
        require(target != address(0) && target.code.length > 0, string.concat(name, " not deployed"));
    }

    function _ensureBackendAdmin() internal {
        // Vault membership management requires BACKEND_ADMIN.
        if (backendAdmin != address(0) && addrMgr.hasRole(Roles.BACKEND_ADMIN, backendAdmin)) return;

        address owner = addrMgr.owner();
        backendAdmin = makeAddr("backendAdmin");

        vm.prank(owner);
        addrMgr.proposeRoleHolder(Roles.BACKEND_ADMIN, backendAdmin);

        vm.prank(backendAdmin);
        addrMgr.acceptProposedRole(Roles.BACKEND_ADMIN);
    }

    function _ensureUnpaused() internal {
        // Unpause protocol components if the pause guardian exists.
        if (pauseGuardian == address(0)) return;

        if (vault.paused()) {
            console2.log("Unpausing vault...");
            vm.prank(pauseGuardian);
            vault.unpause();
        }

        if (aggregator.paused()) {
            console2.log("Unpausing aggregator...");
            vm.prank(pauseGuardian);
            aggregator.unpause();
        }

        if (uniV3.paused()) {
            console2.log("Unpausing uniV3 strategy...");
            vm.prank(pauseGuardian);
            uniV3.unpause();
        }
    }

    function _assertStrategyIsConfigured() internal view {
        // Expect a single active strategy (UniV3) with a non-zero weight.
        bool found;
        uint256 activeCount;
        SubStrategy[] memory subs = aggregator.getSubStrategies();
        for (uint256 i; i < subs.length; ++i) {
            if (subs[i].isActive && subs[i].targetWeightBPS > 0) {
                activeCount++;
            }
            if (address(subs[i].strategy) == address(uniV3)) {
                found = true;
            }
        }
        require(found, "uniV3 not in aggregator");
        require(activeCount == 1, "unexpected active strategies");
    }

    function _ensureDefaultWithdrawPayload() internal {
        // Aggregator uses default withdraw payload when the bundle omits a strategy.
        bytes memory swapToUnderlying = _encodeSwapDataExactInBps(address(other), address(asset), uint16(MAX_BPS));
        bytes memory payload = _encodeV3ActionData(0, bytes(""), swapToUnderlying, 0, 0, 0);

        vm.prank(operator);
        aggregator.setDefaultWithdrawPayload(address(uniV3), payload);
    }

    function _depositUsers() internal {
        // Multi-user deposits to exercise membership + accounting.
        console2.log("Depositing users...");
        uint256 s1 = _deposit(alice, 5_000e6);
        uint256 s2 = _deposit(bob, 3_000e6);
        uint256 s3 = _deposit(charlie, 2_000e6);

        assertGt(s1 + s2 + s3, 0);
        assertEq(vaultLens.getUserShares(address(vault), alice), vault.balanceOf(alice));
        assertEq(sfLens.vaultGetUserShares(address(vault), bob), vault.balanceOf(bob));
        console2.log("====================================");
    }

    function _investHalfIdle() internal {
        console2.log("Idle assets before invest:", vault.idleAssets() / 1e6, "USDC");
        console2.log("Investing half of idle assets into UniV3 strategy...");
        // Invest half of the vault's idle USDC into the UniV3 strategy.
        uint256 idle = vault.idleAssets();
        uint256 investAmount = idle / 2;
        assertGt(investAmount, 0);

        bytes memory investAction = _buildDepositActionData();
        (address[] memory strategies, bytes[] memory payloads) = _singleStrategyPayload(investAction);

        vm.prank(keeper);
        vault.investIntoStrategy(investAmount, strategies, payloads);
        assertGt(uniV3.positionTokenId(), 0);
        console2.log("====================================");
    }

    function _assertLensState() internal view {
        // Cross-check lens outputs against core contracts for consistency.
        uint256 aggAssets = vault.aggregatorAssets();
        assertGt(aggAssets, 0);

        assertEq(vaultLens.getAggregatorAssets(address(vault)), aggAssets);
        assertEq(sfLens.vaultGetAggregatorAssets(address(vault)), aggAssets);

        StrategyConfig memory aggCfg = aggregatorLens.getConfig(address(aggregator));
        assertEq(aggCfg.vault, address(vault));
        assertEq(aggCfg.asset, address(asset));

        bytes memory aggDetails = aggregatorLens.getPositionDetails(address(aggregator));
        (address[] memory aggStrats,,) = abi.decode(aggDetails, (address[], uint16[], bool[]));
        assertTrue(_contains(aggStrats, address(uniV3)));
    }

    function _harvestAndRebalance() internal {
        // Create some fees, harvest them, then rebalance the tick range.
        _seedFees();
        vm.warp(block.timestamp + 3 days);
        _seedFees();

        console2.log("Harvesting rewards and fees from aggregator...");
        bytes memory harvestAction = _buildWithdrawActionData();
        vm.prank(keeper);
        aggregator.harvest(_perStrategyData(harvestAction));
        console2.log("====================================");

        console2.log("Rebalancing UniV3 strategy to a new tick range...");
        (bytes memory rebalanceData, int24 newLower, int24 newUpper) = _buildRebalanceData();
        vm.prank(keeper);
        aggregator.rebalance(_perStrategyData(rebalanceData));
        console2.log("====================================");

        (uint8 version,, address poolAddr, int24 tickLower, int24 tickUpper) =
            abi.decode(uniV3Lens.getPositionDetails(address(uniV3)), (uint8, uint256, address, int24, int24));
        assertEq(version, 1);
        assertEq(poolAddr, address(pool));
        assertEq(tickLower, newLower);
        assertEq(tickUpper, newUpper);
    }

    function _withdrawFromStrategyAndUser() internal {
        console2.log("Withdrawing assets back from strategy to vault...");
        // Pull assets back to the vault and allow a user to withdraw.
        uint256 withdrawRequest = vault.aggregatorAssets() / 3;
        bytes memory withdrawAction = _buildWithdrawActionData();
        (address[] memory strategies, bytes[] memory withdrawPayloads) = _singleStrategyPayload(withdrawAction);

        vm.prank(keeper);
        uint256 withdrawn = vault.withdrawFromStrategy(withdrawRequest, strategies, withdrawPayloads);
        assertGt(withdrawn, 0);
        console2.log("====================================");
        uint256 userAssets = vault.previewRedeem(vault.balanceOf(alice));
        uint256 userWithdraw = _min(userAssets / 2, vault.idleAssets() / 2);
        if (userWithdraw > 0) {
            console2.log("User withdrawing from vault...");
            vm.prank(alice);
            vault.withdraw(userWithdraw, alice, alice);
            console2.log("====================================");
        }
    }

    function _finalAssertions() internal view {
        // Final sanity checks for lenses and helper utilities.
        assertEq(sfLens.vaultGetVaultTVL(address(vault)), vault.totalAssets());
        assertEq(
            sfLens.aggregatorGetPositionValue(address(aggregator)), aggregatorLens.positionValue(address(aggregator))
        );
        assertEq(sfLens.uniswapGetPositionValue(address(uniV3)), uniV3Lens.positionValue(address(uniV3)));

        uint160 sqrtRatio = mathHelper.getSqrtRatioAtTick(0);
        assertGt(sqrtRatio, 0);

        uint256 quote = valuator.quote(address(other), 1_000_000, address(asset));
        assertGt(quote, 0);
    }

    function _registerAndFundUsers() internal {
        // Create test users, register them as members, and fund/approve for deposits.
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        vm.startPrank(backendAdmin);
        for (uint256 i; i < users.length; ++i) {
            vault.registerMember(users[i]);
        }
        vm.stopPrank();

        for (uint256 i; i < users.length; ++i) {
            deal(address(asset), users[i], 10_000e6);
            vm.startPrank(users[i]);
            asset.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        console2.log("Depositing...");
        console2.log("====================================");
        // Respect vault maxDeposit and skip if zero.
        uint256 maxDep = vault.maxDeposit(user);
        uint256 toDeposit = amount > maxDep ? maxDep : amount;
        if (toDeposit == 0) return 0;

        vm.prank(user);
        shares = vault.deposit(toDeposit, user);
    }

    function _seedFees() internal {
        console2.log("Seeding fees in the pool by swapping both directions...");
        console2.log("====================================");
        // Generate pool fees by swapping both directions.
        bool token0IsAsset = pool.token0() == address(asset);
        uint256 amount = 1_000e6;

        deal(address(asset), address(swapper), amount);
        swapper.swapExactIn(token0IsAsset, amount);

        deal(address(other), address(swapper), amount);
        swapper.swapExactIn(!token0IsAsset, amount);
    }

    function _singleStrategyPayload(bytes memory childData)
        internal
        view
        returns (address[] memory strategies, bytes[] memory payloads)
    {
        // Single-strategy bundle wrapper for the aggregator.
        strategies = new address[](1);
        payloads = new bytes[](1);
        strategies[0] = address(uniV3);
        payloads[0] = childData;
    }

    function _perStrategyData(bytes memory childData) internal view returns (bytes memory) {
        // ABI-encode a single-strategy bundle.
        (address[] memory strategies, bytes[] memory payloads) = _singleStrategyPayload(childData);
        return abi.encode(strategies, payloads);
    }

    function _encodeSwapDataExactInBps(address tokenIn, address tokenOut, uint16 bps)
        internal
        pure
        returns (bytes memory)
    {
        // Encode a swap using the strategy's BPS sentinel (amountIn computed at runtime).
        uint256 amountIn = AMOUNT_IN_BPS_FLAG | uint256(bps);
        tokenIn;
        tokenOut;
        return _encodeRankedSwapData(amountIn, uint256(0));
    }

    function _encodeRankedSwapData(uint256 amountIn, uint256 deadline) internal pure returns (bytes memory) {
        uint8[2] memory routeIds;
        uint256[2] memory amountOutMins;
        routeIds[0] = 1;
        routeIds[1] = 2;
        return abi.encode(amountIn, deadline, uint8(2), routeIds, amountOutMins);
    }

    function _encodeV3ActionData(
        uint16 otherRatioBPS,
        bytes memory swapToOtherData,
        bytes memory swapToUnderlyingData,
        uint256 pmDeadline,
        uint256 minUnderlying,
        uint256 minOther
    ) internal pure returns (bytes memory) {
        // Shared action data encoding for UniV3 strategy entrypoints.
        return abi.encode(otherRatioBPS, swapToOtherData, swapToUnderlyingData, pmDeadline, minUnderlying, minOther);
    }

    function _buildDepositActionData() internal view returns (bytes memory) {
        // Target 50/50 ratio by swapping part of underlying into otherToken.
        bytes memory swapToOther = _encodeSwapDataExactInBps(address(asset), address(other), uint16(MAX_BPS));
        return _encodeV3ActionData(5_000, swapToOther, bytes(""), 0, 0, 0);
    }

    function _buildWithdrawActionData() internal view returns (bytes memory) {
        // Swap all otherToken back to underlying on withdraw.
        bytes memory swapToUnderlying = _encodeSwapDataExactInBps(address(other), address(asset), uint16(MAX_BPS));
        return _encodeV3ActionData(0, bytes(""), swapToUnderlying, 0, 0, 0);
    }

    function _buildRebalanceData() internal view returns (bytes memory data, int24 lower, int24 upper) {
        // Choose a symmetric range around the current tick and align to tick spacing.
        (, int24 tickNow,,,,,) = pool.slot0();
        int24 spacing = pool.tickSpacing();

        // +/- 600 ticks keeps the range tight enough to represent a rebalance.
        lower = _floorToSpacing(tickNow - 600, spacing);
        upper = _floorToSpacing(tickNow + 600, spacing);
        if (upper <= lower) upper = lower + spacing;

        // Include action data so the strategy can swap to its target ratio before minting.
        bytes memory actionData = _buildRebalanceActionData();
        data = abi.encode(lower, upper, actionData);
    }

    function _buildRebalanceActionData() internal view returns (bytes memory) {
        // Provide both swap directions using BPS sentinel amounts.
        // This lets the strategy rebalance from a single-sided position.
        bytes memory swapToOther = _encodeSwapDataExactInBps(address(asset), address(other), uint16(MAX_BPS));
        bytes memory swapToUnderlying = _encodeSwapDataExactInBps(address(other), address(asset), uint16(MAX_BPS));
        return _encodeV3ActionData(5_000, swapToOther, swapToUnderlying, 0, 0, 0);
    }

    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        // Round down to the nearest valid tick; handle negative ticks safely.
        int24 mod = tick % spacing;
        int24 floored = tick - mod;
        if (mod < 0) floored -= spacing;
        return floored;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        // Tiny helper to keep arithmetic readable.
        return a < b ? a : b;
    }

    function _contains(address[] memory list, address target) internal pure returns (bool) {
        // Linear scan is fine here (lens outputs are tiny).
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == target) return true;
        }
        return false;
    }
}

contract AddressGetter is GetContractAddress {
    function getAddress(uint256 chainId, string memory contractName) external view returns (address) {
        return _getContractAddress(chainId, contractName);
    }
}

contract UniV3SwapHelper is IUniswapV3SwapCallback {
    using SafeERC20 for IERC20;

    IUniswapV3Pool internal immutable pool;
    IERC20 internal immutable token0;
    IERC20 internal immutable token1;

    constructor(address pool_) {
        pool = IUniswapV3Pool(pool_);
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());
    }

    function swapExactIn(bool zeroForOne, uint256 amountIn) external returns (uint256 amountOut) {
        require(amountIn > 0, "amountIn=0");
        (int256 amount0, int256 amount1) = pool.swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            zeroForOne ? TickMathV3.MIN_SQRT_RATIO + 1 : TickMathV3.MAX_SQRT_RATIO - 1,
            bytes("")
        );
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
        require(msg.sender == address(pool), "pool");
        if (amount0Delta > 0) token0.safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) token1.safeTransfer(msg.sender, uint256(amount1Delta));
    }
}
