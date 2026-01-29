// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeploySFStrategyAggregator} from "test/utils/06-DeploySFStrategyAggregator.s.sol";
import {DeploySFAndIFCircuitBreaker} from "test/utils/08-DeployCircuitBreaker.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {SFAndIFCircuitBreaker} from "contracts/breakers/SFAndIFCircuitBreaker.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/SFUniswapV3Strategy.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UniswapV3MathHelper} from "contracts/helpers/uniswapHelpers/UniswapV3MathHelper.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {VaultsPauseFlags} from "contracts/helpers/libraries/flags/VaultsPauseFlags.sol";
import {RequestKind, WithdrawalRequest} from "contracts/types/CircuitBreakerTypes.sol";

contract SFCircuitBreakerTest is Test {
    using SafeERC20 for IERC20;

    DeployManagers internal managersDeployer;
    DeploySFStrategyAggregator internal aggregatorDeployer;
    DeploySFAndIFCircuitBreaker internal circuitBreakerDeployer;
    AddAddressesAndRoles internal addressesAndRoles;

    SFVault internal vault;
    SFStrategyAggregator internal aggregator;
    SFUniswapV3Strategy internal uniV3Strategy;
    AddressManager internal addrMgr;
    ModuleManager internal modMgr;
    SFAndIFCircuitBreaker internal circuitBreaker;

    IERC20 internal asset;
    IERC20 internal usdt;

    address internal takadao; // operator
    address internal feeRecipient;
    address internal pauser = makeAddr("pauser");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant MAX_BPS = 10_000;

    // Arbitrum tokens
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ARB_USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    // Uniswap V3 addresses
    address internal constant POOL_USDC_USDT = 0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6;
    address internal constant NONFUNGIBLE_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address internal constant UNIVERSAL_ROUTER = 0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3;

    int24 internal constant TICK_LOWER = -200;
    int24 internal constant TICK_UPPER = 200;

    function setUp() public {
        // Fork Arbitrum mainnet
        string memory rpcUrl = vm.envString("ARBITRUM_MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        managersDeployer = new DeployManagers();
        aggregatorDeployer = new DeploySFStrategyAggregator();
        circuitBreakerDeployer = new DeploySFAndIFCircuitBreaker();
        addressesAndRoles = new AddAddressesAndRoles();

        (HelperConfig.NetworkConfig memory config, AddressManager _addrMgr, ModuleManager _modMgr) =
            managersDeployer.run();
        (address operatorAddr,,,,,,) = addressesAndRoles.run(_addrMgr, config, address(_modMgr));
        circuitBreaker = circuitBreakerDeployer.run(_addrMgr);

        addrMgr = _addrMgr;
        modMgr = _modMgr;
        takadao = operatorAddr;

        // Deploy a UUPS proxy for the vault
        address vaultImplementation = address(new SFVault());
        address vaultAddress = UnsafeUpgrades.deployUUPSProxy(
            vaultImplementation, abi.encodeCall(SFVault.initialize, (addrMgr, IERC20(ARB_USDC), "SF Vault", "SFV"))
        );
        vault = SFVault(vaultAddress);
        asset = IERC20(vault.asset());
        usdt = IERC20(ARB_USDT);

        // Deploy aggregator and set as vault strategy
        aggregator = aggregatorDeployer.run(addrMgr, asset, address(vault));

        vm.startPrank(takadao);
        vault.whitelistToken(ARB_USDT);
        vault.setAggregator(ISFStrategy(address(aggregator)));
        vm.stopPrank();

        // Fee recipient required by SFVault
        feeRecipient = makeAddr("feeRecipient");
        vm.startPrank(addrMgr.owner());
        addrMgr.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", feeRecipient, ProtocolAddressType.Admin);
        addrMgr.addProtocolAddress("PROTOCOL__CIRCUIT_BREAKER", address(circuitBreaker), ProtocolAddressType.Admin);
        addrMgr.addProtocolAddress("PROTOCOL__SF_VAULT", address(vault), ProtocolAddressType.Protocol);
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(aggregator), ProtocolAddressType.Protocol);
        vm.stopPrank();

        // Pause guardian role for pause/unpause coverage
        vm.startPrank(addrMgr.owner());
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN, true);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauser);
        vm.stopPrank();

        vm.prank(pauser);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);

        vm.prank(addrMgr.owner());
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, address(circuitBreaker));

        vm.prank(takadao);
        circuitBreaker.acceptPauserRole();

        // Deploy Uni V3 strategy (UUPS proxy)
        UniswapV3MathHelper mathHelper = new UniswapV3MathHelper();
        address stratImplementation = address(new SFUniswapV3Strategy());
        address stratProxy = UnsafeUpgrades.deployUUPSProxy(
            stratImplementation,
            abi.encodeCall(
                SFUniswapV3Strategy.initialize,
                (
                    addrMgr,
                    address(vault),
                    IERC20(ARB_USDC),
                    IERC20(ARB_USDT),
                    POOL_USDC_USDT,
                    NONFUNGIBLE_POSITION_MANAGER,
                    address(mathHelper),
                    100_000e6, // max TVL (USDC 6 decimals)
                    UNIVERSAL_ROUTER,
                    TICK_LOWER,
                    TICK_UPPER
                )
            )
        );
        uniV3Strategy = SFUniswapV3Strategy(stratProxy);

        // The only strategy in the aggregator
        vm.prank(takadao);
        aggregator.addSubStrategy(address(uniV3Strategy), 10_000);
    }

    /*//////////////////////////////////////////////////////////////
                                TESTS
    //////////////////////////////////////////////////////////////*/

    function testCircuitBreaker_sanity() public view {
        assertEq(address(circuitBreaker), addrMgr.getProtocolAddressByName("PROTOCOL__CIRCUIT_BREAKER").addr);
        assertEq(address(vault), addrMgr.getProtocolAddressByName("PROTOCOL__SF_VAULT").addr);
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    function testCircuitBreaker_acceptPauserRoleRevertsIfNotOperator() public {
        vm.prank(stranger);
        vm.expectRevert(SFAndIFCircuitBreaker.SFAndIFCircuitBreaker__NotAuthorizedCaller.selector);
        circuitBreaker.acceptPauserRole();
    }

    function testCircuitBreaker_setGuardsRevertIfVaultZero() public {
        vm.prank(takadao);
        vm.expectRevert(SFAndIFCircuitBreaker.SFAndIFCircuitBreaker__InvalidConfig.selector);
        circuitBreaker.setGuards(address(0), 1, 2, 3, true);
    }

    function testCircuitBreaker_setGuardsRevertIfNotOperator() public {
        vm.prank(stranger);
        vm.expectRevert(SFAndIFCircuitBreaker.SFAndIFCircuitBreaker__NotAuthorizedCaller.selector);
        circuitBreaker.setGuards(address(vault), 1, 2, 3, true);
    }

    function testCircuitBreaker_approveWithdrawalRequestRevertInvalidRequest() public {
        vm.prank(takadao);
        vm.expectRevert(SFAndIFCircuitBreaker.SFAndIFCircuitBreaker__InvalidRequest.selector);
        circuitBreaker.approveWithdrawalRequest(999999);
    }

    function testCircuitBreaker_cancelWithdrawalRequestRevertInvalidRequest() public {
        vm.prank(takadao);
        vm.expectRevert(SFAndIFCircuitBreaker.SFAndIFCircuitBreaker__InvalidRequest.selector);
        circuitBreaker.cancelWithdrawalRequest(999999);
    }

    function testCircuitBreaker_queueRequestRevertOnZeroOwnerOrReceiver() public {
        _enableGuardsForVault(0, 0, 100e6);

        // Call hookWithdraw directly as the vault (so onlyProtectedCaller passes) with bad owner/receiver.
        vm.prank(address(vault));
        vm.expectRevert(SFAndIFCircuitBreaker.SFAndIFCircuitBreaker__InvalidRequest.selector);
        circuitBreaker.hookWithdraw(address(0), bob, 100e6);

        vm.prank(address(vault));
        vm.expectRevert(SFAndIFCircuitBreaker.SFAndIFCircuitBreaker__InvalidRequest.selector);
        circuitBreaker.hookWithdraw(alice, address(0), 100e6);
    }

    function testCircuitBreaker_hookWithdrawRevertsIfNotProtected() public {
        _depositToVault(alice, 200e6);

        vm.prank(alice);
        vm.expectRevert(SFAndIFCircuitBreaker.SFAndIFCircuitBreaker__NotProtected.selector);
        vault.withdraw(10e6, alice, alice);
    }

    function testCircuitBreaker_hookExecuteApprovedRevertIfWrongVaultOrNonexistent() public {
        _enableGuardsForVault(0, 0, 100e6);

        // Nonexistent requestId => r.vault == 0, require(r.vault == msg.sender) fails.
        vm.prank(address(vault));
        vm.expectRevert(SFAndIFCircuitBreaker.SFAndIFCircuitBreaker__InvalidRequest.selector);
        circuitBreaker.hookExecuteApproved(123456, 1);
    }

    /*//////////////////////////////////////////////////////////////
                                CONFIGS
    //////////////////////////////////////////////////////////////*/

    function testCircuitBreaker_setGuardsUpdatesConfig() public {
        _enableGuardsForVault(111, 222, 333);

        (uint256 g, uint256 u, uint256 th, bool en) = circuitBreaker.config(address(vault));
        assertEq(g, 111);
        assertEq(u, 222);
        assertEq(th, 333);
        assertTrue(en);
    }

    function testCircuitBreaker_resetWindowsGlobalOnly() public {
        _enableGuardsForVault(200e6, 0, 0);
        _depositToVault(alice, 500e6);

        // Consume once so windows are initialized.
        vm.prank(alice);
        uint256 out = vault.withdraw(50e6, alice, alice);
        assertEq(out, 50e6);

        (uint64 startBefore, uint256 withdrawnBefore,,,) = circuitBreaker.getGlobalWindowState(address(vault));
        assertGt(startBefore, 0);
        assertEq(withdrawnBefore, 50e6);

        // Reset global window only
        vm.warp(block.timestamp + 123);
        vm.prank(takadao);
        circuitBreaker.resetWindows(address(vault), address(0));

        (uint64 startAfter, uint256 withdrawnAfter,,,) = circuitBreaker.getGlobalWindowState(address(vault));
        assertEq(startAfter, uint64(block.timestamp));
        assertEq(withdrawnAfter, 0);
    }

    function testCircuitBreaker_resetWindowsGlobalAndUser() public {
        _enableGuardsForVault(200e6, 100e6, 0);
        _depositToVault(alice, 500e6);

        vm.prank(alice);
        uint256 out = vault.withdraw(60e6, alice, alice);
        assertEq(out, 60e6);

        (, uint256 gWithdrawnBefore,,,) = circuitBreaker.getGlobalWindowState(address(vault));
        (, uint256 uWithdrawnBefore,,,) = circuitBreaker.getUserWindowState(address(vault), alice);
        assertEq(gWithdrawnBefore, 60e6);
        assertEq(uWithdrawnBefore, 60e6);

        vm.warp(block.timestamp + 77);
        vm.prank(takadao);
        circuitBreaker.resetWindows(address(vault), alice);

        (, uint256 gWithdrawnAfter,,,) = circuitBreaker.getGlobalWindowState(address(vault));
        (, uint256 uWithdrawnAfter,,,) = circuitBreaker.getUserWindowState(address(vault), alice);
        assertEq(gWithdrawnAfter, 0);
        assertEq(uWithdrawnAfter, 0);
    }

    /*//////////////////////////////////////////////////////////////
                             LARGE WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function testCircuitBreaker_requiresApprovalBehaviour() public {
        // Not enabled => false
        (bool req0) = circuitBreaker.requiresApproval(address(vault), 100);
        assertFalse(req0);

        _enableGuardsForVault(0, 0, 123);

        assertFalse(circuitBreaker.requiresApproval(address(vault), 122));
        assertTrue(circuitBreaker.requiresApproval(address(vault), 123));
        assertTrue(circuitBreaker.requiresApproval(address(vault), 999));
    }

    /*//////////////////////////////////////////////////////////////
                                 HOOKS
    //////////////////////////////////////////////////////////////*/

    function testCircuitBreaker_wouldExceedRateLimitView() public {
        _enableGuardsForVault(100e6, 50e6, 0);
        _depositToVault(alice, 500e6);

        // First withdraw consumes 40e6 => below both caps.
        vm.prank(alice);
        uint256 out = vault.withdraw(40e6, alice, alice);
        assertEq(out, 40e6);

        // Check wouldExceed for +61e6:
        // global: 40 + 61 = 101 > 100 => exceeded
        // user:   40 + 61 = 101 > 50  => exceeded
        (bool globalExceeded, bool userExceeded) = circuitBreaker.wouldExceedRateLimit(address(vault), alice, 61e6);
        assertTrue(globalExceeded);
        assertTrue(userExceeded);
    }

    function testCircuitBreaker_hookWithdrawLargeWithdrawalQueuesAndPausesVault() public {
        _enableGuardsForVault(0, 0, 100e6);
        _depositToVault(alice, 500e6);

        uint256 requestId = _queueLargeWithdrawViaVault(alice, bob, 200e6);

        assertTrue(vault.paused());
        assertTrue(circuitBreaker.tripped(address(vault)));

        assertTrue(circuitBreaker.hasPauseFlag(address(vault), VaultsPauseFlags.LARGE_WITHDRAW_QUEUED_FLAG));
        assertEq(circuitBreaker.getPauseFlags(address(vault)), VaultsPauseFlags.LARGE_WITHDRAW_QUEUED_FLAG);

        // Request sanity
        WithdrawalRequest memory r = circuitBreaker.getWithdrawalRequest(requestId);
        assertFalse(r.approved);
        assertFalse(r.executed);
        assertFalse(r.cancelled);
        assertEq(r.createdAt, uint64(block.timestamp));
    }

    function testCircuitBreaker_hookRedeemLargeRedeemQueuesAndPausesVault() public {
        _enableGuardsForVault(0, 0, 100e6);
        uint256 sharesMinted = _depositToVault(alice, 500e6);

        // previewRedeem(shares) >= threshold.
        // previewWithdraw(thresholdAssets) should be approximate inverse.
        uint256 sharesToRedeem = vault.previewWithdraw(200e6);
        // Ensure we have enough shares.
        sharesToRedeem = sharesToRedeem > sharesMinted ? sharesMinted : sharesToRedeem;

        (uint256 requestId, uint256 assetsEst) = _queueLargeRedeemViaVault(alice, bob, sharesToRedeem);

        assertTrue(vault.paused());
        assertTrue(circuitBreaker.tripped(address(vault)));
        assertTrue(circuitBreaker.hasPauseFlag(address(vault), VaultsPauseFlags.LARGE_WITHDRAW_QUEUED_FLAG));

        WithdrawalRequest memory r = circuitBreaker.getWithdrawalRequest(requestId);
        assertEq(uint256(r.kind), uint256(RequestKind.Redeem));
        assertEq(r.assetsRequested, assetsEst);
        assertEq(r.sharesRequested, sharesToRedeem);
    }

    function testCircuitBreaker_hookWithdrawRateLimitAllowsAndConsumesWindows() public {
        _enableGuardsForVault(500e6, 300e6, 0);
        _depositToVault(alice, 700e6);

        vm.prank(alice);
        uint256 out = vault.withdraw(200e6, alice, alice);
        assertEq(out, 200e6);

        (uint64 gStart, uint256 gWithdrawn, uint256 gCap, uint256 gRemaining, uint64 gResetsAt) =
            circuitBreaker.getGlobalWindowState(address(vault));
        (uint64 uStart, uint256 uWithdrawn, uint256 uCap, uint256 uRemaining, uint64 uResetsAt) =
            circuitBreaker.getUserWindowState(address(vault), alice);

        assertEq(gCap, 500e6);
        assertEq(uCap, 300e6);

        assertEq(gWithdrawn, 200e6);
        assertEq(uWithdrawn, 200e6);

        assertEq(gRemaining, 300e6);
        assertEq(uRemaining, 100e6);

        assertEq(gResetsAt, gStart + uint64(1 days));
        assertEq(uResetsAt, uStart + uint64(1 days));

        assertFalse(vault.paused());
    }

    function testCircuitBreaker_hookWithdrawRateLimitExceedPausesAndReturnsZero() public {
        _enableGuardsForVault(100e6, 0, 0);
        _depositToVault(alice, 500e6);

        // Exactly at cap is allowed (strict > check).
        vm.prank(alice);
        uint256 out1 = vault.withdraw(100e6, alice, alice);
        assertEq(out1, 100e6);
        assertFalse(vault.paused());

        // Next withdraw exceeds => circuit breaker triggers pause and short-circuits (returns 0).
        vm.prank(alice);
        uint256 out2 = vault.withdraw(1e6, alice, alice);
        assertEq(out2, 0);
        assertTrue(vault.paused());

        assertTrue(circuitBreaker.hasPauseFlag(address(vault), VaultsPauseFlags.RATE_LIMIT_EXCEEDED_FLAG));

        (, uint256 gWithdrawn,, uint256 remaining,) = circuitBreaker.getGlobalWindowState(address(vault));
        // should remain at 100e6 since the second call doesn't consume
        assertEq(gWithdrawn, 100e6);
        assertEq(remaining, 0);
    }

    function testCircuitBreaker_hookWithdrawUserCapExceedPausesAndReturnsZero() public {
        _enableGuardsForVault(0, 50e6, 0);
        _depositToVault(alice, 500e6);

        vm.prank(alice);
        uint256 out1 = vault.withdraw(50e6, alice, alice);
        assertEq(out1, 50e6);

        vm.prank(alice);
        uint256 out2 = vault.withdraw(1e6, alice, alice);
        assertEq(out2, 0);
        assertTrue(vault.paused());

        assertTrue(circuitBreaker.hasPauseFlag(address(vault), VaultsPauseFlags.RATE_LIMIT_EXCEEDED_FLAG));
    }

    function testCircuitBreaker_windowsResetAfterOneDay() public {
        _enableGuardsForVault(100e6, 0, 0);
        _depositToVault(alice, 500e6);

        vm.prank(alice);
        uint256 out1 = vault.withdraw(100e6, alice, alice);
        assertEq(out1, 100e6);

        (uint64 start1, uint256 withdrawn1,, uint256 remaining1,) = circuitBreaker.getGlobalWindowState(address(vault));
        assertEq(withdrawn1, 100e6);
        assertEq(remaining1, 0);

        // Past the 24h window; view should show a reset window.
        vm.warp(block.timestamp + 1 days + 1);

        (uint64 start2, uint256 withdrawn2,, uint256 remaining2,) = circuitBreaker.getGlobalWindowState(address(vault));
        assertEq(start2, uint64(block.timestamp));
        assertEq(withdrawn2, 0);
        assertEq(remaining2, 100e6);

        // Now withdraw again should be allowed.
        vm.prank(alice);
        uint256 out2 = vault.withdraw(100e6, alice, alice);
        assertEq(out2, 100e6);
    }

    function testCircuitBreaker_clearPauseFlagsAndResetPauseFlags() public {
        _enableGuardsForVault(100e6, 0, 100e6);
        _depositToVault(alice, 500e6);

        // Trigger LARGE_WITHDRAW_QUEUED_FLAG
        _queueLargeWithdrawViaVault(alice, bob, 100e6);
        assertTrue(vault.paused());

        // Unpause so we can continue
        _unpauseIfPaused();

        // Reconfigure to disable approval for subsequent withdrawals,
        // so we can hit RATE_LIMIT_EXCEEDED_FLAG via normal withdraw path.
        _enableGuardsForVault(100e6, 0, type(uint256).max);

        // Consume full global cap (allowed)
        vm.prank(alice);
        uint256 out1 = vault.withdraw(100e6, alice, alice);
        assertEq(out1, 100e6);

        // Exceed cap (should short-circuit to 0 + pause + set RATE_LIMIT_EXCEEDED_FLAG)
        vm.prank(alice);
        uint256 out2 = vault.withdraw(1e6, alice, alice);
        assertEq(out2, 0);
        assertTrue(vault.paused());

        uint256 flags = circuitBreaker.getPauseFlags(address(vault));
        assertTrue((flags & VaultsPauseFlags.LARGE_WITHDRAW_QUEUED_FLAG) != 0);
        assertTrue((flags & VaultsPauseFlags.RATE_LIMIT_EXCEEDED_FLAG) != 0);

        // Clear only RATE_LIMIT flag
        vm.prank(takadao);
        circuitBreaker.clearPauseFlags(address(vault), VaultsPauseFlags.RATE_LIMIT_EXCEEDED_FLAG);

        uint256 flagsAfterClear = circuitBreaker.getPauseFlags(address(vault));
        assertTrue((flagsAfterClear & VaultsPauseFlags.LARGE_WITHDRAW_QUEUED_FLAG) != 0);
        assertTrue((flagsAfterClear & VaultsPauseFlags.RATE_LIMIT_EXCEEDED_FLAG) == 0);

        // Reset all flags
        vm.prank(takadao);
        circuitBreaker.resetPauseFlags(address(vault));
        assertEq(circuitBreaker.getPauseFlags(address(vault)), 0);
    }

    function testCircuitBreaker_approveAndExecuteLargeWithdrawViaVault() public {
        _enableGuardsForVault(0, 0, 100e6);
        _depositToVault(alice, 500e6);

        uint256 bobBalBefore = asset.balanceOf(bob);

        uint256 requestId = _queueLargeWithdrawViaVault(alice, bob, 200e6);
        assertTrue(vault.paused());

        // Vault must be unpaused to execute (whenNotPaused).
        _unpauseIfPaused();

        // Approve request
        vm.prank(takadao);
        circuitBreaker.approveWithdrawalRequest(requestId);
        assertTrue(circuitBreaker.isRequestExecutable(requestId));

        // Execute via vault operator function (burns shares, transfers assets)
        uint256 aliceSharesBefore = vault.balanceOf(alice);

        vm.prank(takadao);
        uint256 assetsOut = vault.executeApprovedCircuitBreakersWithdrawals(requestId);

        assertEq(assetsOut, 200e6);
        assertEq(asset.balanceOf(bob), bobBalBefore + 200e6);

        WithdrawalRequest memory rAfter = circuitBreaker.getWithdrawalRequest(requestId);
        assertTrue(rAfter.approved);
        assertTrue(rAfter.executed);
        assertFalse(rAfter.cancelled);

        // Shares reduced
        uint256 sharesToBurn = vault.previewWithdraw(200e6);
        uint256 aliceSharesAfter = vault.balanceOf(alice);
        assertEq(aliceSharesAfter, aliceSharesBefore - sharesToBurn);
    }

    function testCircuitBreaker_hookExecuteApprovedInvalidStateTriggersPauseFlag() public {
        _enableGuardsForVault(0, 0, 100e6);
        _depositToVault(alice, 500e6);

        uint256 requestId = _queueLargeWithdrawViaVault(alice, bob, 200e6);

        // Unpause and reset flags for a clean assertion of EXECUTE_INVALID_STATE path.
        _unpauseIfPaused();
        vm.prank(takadao);
        circuitBreaker.resetPauseFlags(address(vault));
        assertEq(circuitBreaker.getPauseFlags(address(vault)), 0);

        // Not approved => should trigger EXECUTE_INVALID_STATE and pause.
        vm.prank(address(vault));
        bool proceed = circuitBreaker.hookExecuteApproved(requestId, 200e6);
        assertFalse(proceed);

        assertTrue(vault.paused());
        assertTrue(circuitBreaker.hasPauseFlag(address(vault), VaultsPauseFlags.EXECUTE_INVALID_STATE));
    }

    function testCircuitBreaker_hookExecuteApprovedRateLimitExceededTriggersPauseFlag() public {
        // Enable guards with a cap that makes execution exceed immediately.
        _enableGuardsForVault(100e6, 0, 100e6);
        _depositToVault(alice, 500e6);

        uint256 requestId = _queueLargeWithdrawViaVault(alice, bob, 200e6);

        // Unpause so we can approve without being blocked by whenNotPaused in vault helpers.
        _unpauseIfPaused();

        vm.prank(takadao);
        circuitBreaker.approveWithdrawalRequest(requestId);

        // Reset pause flags so we can assert specifically RATE_LIMIT_EXCEEDED on execute attempt.
        vm.prank(takadao);
        circuitBreaker.resetPauseFlags(address(vault));

        // Call execute hook directly from the vault context; rate limit should trip and pause.
        vm.prank(address(vault));
        bool proceed = circuitBreaker.hookExecuteApproved(requestId, 200e6);
        assertFalse(proceed);

        assertTrue(vault.paused());
        assertTrue(circuitBreaker.hasPauseFlag(address(vault), VaultsPauseFlags.RATE_LIMIT_EXCEEDED_FLAG));
    }

    function testCircuitBreaker_cancelWithdrawalRequestThenExecuteTriggersInvalidState() public {
        _enableGuardsForVault(0, 0, 100e6);
        _depositToVault(alice, 500e6);

        uint256 requestId = _queueLargeWithdrawViaVault(alice, bob, 200e6);

        _unpauseIfPaused();
        vm.prank(takadao);
        circuitBreaker.cancelWithdrawalRequest(requestId);

        // Reset flags so we can assert EXECUTE_INVALID_STATE.
        vm.prank(takadao);
        circuitBreaker.resetPauseFlags(address(vault));
        assertEq(circuitBreaker.getPauseFlags(address(vault)), 0);

        vm.prank(address(vault));
        bool proceed = circuitBreaker.hookExecuteApproved(requestId, 200e6);
        assertFalse(proceed);

        assertTrue(circuitBreaker.hasPauseFlag(address(vault), VaultsPauseFlags.EXECUTE_INVALID_STATE));
    }

    // /*//////////////////////////////////////////////////////////////
    //                            HELPERS
    // //////////////////////////////////////////////////////////////*/

    function _ensureBackendAdmin(address _account) internal {
        if (addrMgr.hasRole(Roles.BACKEND_ADMIN, _account)) return;

        vm.startPrank(addrMgr.owner());
        // Be defensive: create role if it doesn't exist yet.
        if (!addrMgr.isValidRole(Roles.BACKEND_ADMIN)) {
            addrMgr.createNewRole(Roles.BACKEND_ADMIN, true);
        }
        addrMgr.proposeRoleHolder(Roles.BACKEND_ADMIN, _account);
        vm.stopPrank();

        vm.prank(_account);
        addrMgr.acceptProposedRole(Roles.BACKEND_ADMIN);

        assertTrue(addrMgr.hasRole(Roles.BACKEND_ADMIN, _account));
    }

    function _registerMember(address _member) internal {
        _ensureBackendAdmin(takadao);
        vm.prank(takadao);
        vault.registerMember(_member);
    }

    function _depositToVault(address _user, uint256 _assetsAmount) internal returns (uint256 sharesMinted_) {
        _registerMember(_user);

        deal(address(asset), _user, _assetsAmount);

        vm.startPrank(_user);
        asset.approve(address(vault), _assetsAmount);
        sharesMinted_ = vault.deposit(_assetsAmount, _user);
        vm.stopPrank();

        assertGt(sharesMinted_, 0);
    }

    function _enableGuardsForVault(uint256 _globalCap, uint256 _userCap, uint256 _approvalThreshold) internal {
        vm.prank(takadao);
        circuitBreaker.setGuards(address(vault), _globalCap, _userCap, _approvalThreshold, true);

        (uint256 g, uint256 u, uint256 th, bool en) = circuitBreaker.config(address(vault));
        assertEq(g, _globalCap);
        assertEq(u, _userCap);
        assertEq(th, _approvalThreshold);
        assertTrue(en);
    }

    function _unpauseIfPaused() internal {
        if (vault.paused()) {
            vm.prank(pauser);
            vault.unpause();
            assertFalse(vault.paused());
        }
    }

    function _queueLargeWithdrawViaVault(address _owner, address _receiver, uint256 _assetsAmount)
        internal
        returns (uint256 requestId_)
    {
        // Trigger large-withdraw flow via SFVault.withdraw => circuit breaker hook.
        vm.prank(_owner);
        uint256 out = vault.withdraw(_assetsAmount, _receiver, _owner);
        assertEq(out, 0); // circuit breaker short-circuits (no revert)

        // requestId is stored as circuitBreaker.nextRequestId() after queue because _queueRequest does ++nextRequestId.
        requestId_ = circuitBreaker.nextRequestId();
        WithdrawalRequest memory r = circuitBreaker.getWithdrawalRequest(requestId_);

        assertEq(r.vault, address(vault));
        assertEq(r.owner, _owner);
        assertEq(r.receiver, _receiver);
        assertEq(uint256(r.kind), uint256(RequestKind.Withdraw));
        assertEq(r.assetsRequested, _assetsAmount);
        assertEq(r.sharesRequested, vault.previewWithdraw(_assetsAmount));
    }

    function _queueLargeRedeemViaVault(address _owner, address _receiver, uint256 _sharesAmount)
        internal
        returns (uint256 requestId_, uint256 assetsEstimated_)
    {
        vm.prank(_owner);
        uint256 outAssets = vault.redeem(_sharesAmount, _receiver, _owner);
        assertEq(outAssets, 0);

        requestId_ = circuitBreaker.nextRequestId();
        WithdrawalRequest memory r = circuitBreaker.getWithdrawalRequest(requestId_);
        assetsEstimated_ = vault.previewRedeem(_sharesAmount);

        assertEq(r.vault, address(vault));
        assertEq(r.owner, _owner);
        assertEq(r.receiver, _receiver);
        assertEq(uint256(r.kind), uint256(RequestKind.Redeem));
        assertEq(r.assetsRequested, assetsEstimated_);
        assertEq(r.sharesRequested, _sharesAmount);
    }
}
