// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFAndIFCircuitBreaker
 * @author Maikel Ordaz
 * @notice Circuit Breaker contract for Save Funds and Investment Fund modules
 * @dev Upgradeable contract with UUPS pattern
 *
 * Design notes:
 * - Intended to be shared across multiple "protected" contracts (e.g., SFVault, IFVault, etc).
 * - For queued withdrawals, this contract escrows vault shares (IERC20(vault).transferFrom),
 *   then executes via IERC4626(vault).redeem at execution time (share-based queue).
 * - For "pause inside same tx", callers MUST NOT revert after this contract pauses,
 *   otherwise the pause is rolled back. Use the boolean-return pattern for keeper/operator flows.
 */

pragma solidity 0.8.28;

import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ISFVault} from "contracts/interfaces/saveFunds/ISFVault.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract SFAndIFCircuitBreaker is Initializable, UUPSUpgradeable, ReentrancyGuardTransientUpgradeable {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    struct GuardConfig {
        // --- Rate limits (24h rolling window) ---
        uint256 globalWithdrawCap24hAssets; // 0 disables
        uint256 userWithdrawCap24hAssets; // 0 disables

        // --- Timelocks (queueing) ---
        bool globalWithdrawTimelockEnabled;
        uint64 globalWithdrawTimelockDelay; // seconds
        uint256 timelockThresholdAssets; // assets threshold
        uint64 timelockDelay; // seconds (for threshold-based timelock)

        // --- Approvals ---
        uint256 approvalThresholdAssets; // if estimated assets >= threshold => needsApproval

        // --- Strategy unwind anomaly ---
        uint16 minStrategyUnwindBps; // e.g., 9500 => withdrawn >= 95% of requested; 0 disables

        // --- Emergency toggles ---
        bool enabled; // master enable for this protected contract
        bool blockKeeperFlowsWhenTripped; // if tripped, keeper-like checks return false (no revert)
    }

    struct Window {
        uint64 start;
        uint256 withdrawn;
    }

    struct WithdrawalRequest {
        address vault;
        address owner;
        address receiver;
        uint128 shares;
        uint64 unlockTime;

        bool needsApproval;
        bool approved;

        bool executed;
        bool cancelled;
    }

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    error SFAndIFCircuitBreaker__NotAuthorizedCaller();
    error SFAndIFCircuitBreaker__NotProtected();
    error SFAndIFCircuitBreaker__RateLimitExceeded();
    error SFAndIFCircuitBreaker__WithdrawalRequiresQueue();
    error SFAndIFCircuitBreaker__NotUnlocked();
    error SFAndIFCircuitBreaker__NotApproved();
    error SFAndIFCircuitBreaker__InvalidRequest();
    error SFAndIFCircuitBreaker__TransferFailed();

    event OnGuardsUpdated(address indexed vault, GuardConfig config);
    event OnWindowsReset(address indexed vault, address indexed user);

    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed vault,
        address indexed owner,
        address receiver,
        uint256 shares,
        uint64 unlockTime,
        bool needsApproval
    );
    event WithdrawalCancelled(uint256 indexed requestId, address indexed vault, address indexed owner);
    event WithdrawalApproved(uint256 indexed requestId, address indexed vault, address indexed approver);
    event WithdrawalExecuted(
        uint256 indexed requestId, address indexed vault, address indexed executor, uint256 assetsOut
    );

    event CircuitBreakerTripped(address indexed vault, bytes32 indexed reason, bytes data);
    event PauseAttempt(address indexed target, bool success, bytes returndata);

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    IAddressManager private addressManager;

    // Per-protected-contract configuration
    mapping(address => GuardConfig) public config;

    // Tripped state per protected contract (used for keeper-flow boolean return pattern)
    mapping(address => bool) public tripped;

    // 24h rolling windows
    mapping(address => Window) public globalWindow; // vault => window
    mapping(address => mapping(address => Window)) public userWindow; // vault => user => window

    // Queue state
    uint256 public nextRequestId;
    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyRole(bytes32 role) {
        require(addressManager.hasRole(role, msg.sender), SFAndIFCircuitBreaker__NotAuthorizedCaller());
        _;
    }

    modifier onlyProtectedCaller() {
        // The *caller* is expected to be a protected contract (e.g., SFVault) in hook-style calls.
        GuardConfig memory cfg = config[msg.sender];
        require(cfg.enabled, SFAndIFCircuitBreaker__NotProtected());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IAddressManager _addressManager) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        addressManager = _addressManager;

        // Start request ids at 1 to keep "0" as an invalid sentinel.
        nextRequestId = 1;
    }

    /*//////////////////////////////////////////////////////////////
                           CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configure guards for a protected contract (e.g., SFVault).
     */
    // todo: OPERATOR or BACKEND_ADMIN?
    function setWithdrawalGuards(
        address vault,
        uint256 globalWithdrawCap24hAssets,
        uint256 userWithdrawCap24hAssets,
        bool globalWithdrawTimelockEnabled,
        uint64 globalWithdrawTimelockDelay,
        uint256 timelockThresholdAssets,
        uint64 timelockDelay,
        uint256 approvalThresholdAssets,
        uint16 minStrategyUnwindBps,
        bool blockKeeperFlowsWhenTripped,
        bool enabled
    ) external onlyRole(Roles.OPERATOR) {
        GuardConfig storage cfg = config[vault];

        cfg.globalWithdrawCap24hAssets = globalWithdrawCap24hAssets;
        cfg.userWithdrawCap24hAssets = userWithdrawCap24hAssets;

        cfg.globalWithdrawTimelockEnabled = globalWithdrawTimelockEnabled;
        cfg.globalWithdrawTimelockDelay = globalWithdrawTimelockDelay;
        cfg.timelockThresholdAssets = timelockThresholdAssets;
        cfg.timelockDelay = timelockDelay;

        cfg.approvalThresholdAssets = approvalThresholdAssets;

        cfg.minStrategyUnwindBps = minStrategyUnwindBps;

        cfg.blockKeeperFlowsWhenTripped = blockKeeperFlowsWhenTripped;
        cfg.enabled = enabled;

        emit OnGuardsUpdated(vault, cfg);
    }

    /**
     * @notice Optional hard reset counters (admin/ops only).
     * @dev If `user` is zero address, only resets global window.
     */
    function resetWithdrawalWindows(address vault, address user) external onlyRole(Roles.OPERATOR) {
        Window storage gw = globalWindow[vault];
        gw.start = uint64(block.timestamp);
        gw.withdrawn = 0;

        if (user != address(0)) {
            Window storage uw = userWindow[vault][user];
            uw.start = uint64(block.timestamp);
            uw.withdrawn = 0;
        }

        emit OnWindowsReset(vault, user);
    }

    /*//////////////////////////////////////////////////////////////
                          CORE HOOKS (VAULT CALLS)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pre-check for instant ERC4626 withdraw (assets known).
     * @dev Expected caller: the vault itself. Reverts on violations (prevents outflow).
     */
    function beforeWithdraw(address owner, uint256 assets) external nonReentrant onlyProtectedCaller {
        _enforceOrQueue(msg.sender, assets);
        _consumeRateLimit(msg.sender, owner, assets);
    }

    /**
     * @notice Pre-check for instant ERC4626 redeem (shares known, compute assets estimate).
     * @dev Expected caller: the vault itself. Reverts on violations (prevents outflow).
     */
    function beforeRedeem(address owner, uint256 shares)
        external
        nonReentrant
        onlyProtectedCaller
        returns (uint256 assetsEst)
    {
        assetsEst = IERC4626(msg.sender).previewRedeem(shares);
        _enforceOrQueue(msg.sender, assetsEst);
        _consumeRateLimit(msg.sender, owner, assetsEst);
    }

    /**
     * @notice Check that can be used for keeper/operator flows where you want to PAUSE and RETURN FALSE (no revert).
     * @dev Expected caller: protected contract. If tripped, and configured to block keeper flows, returns false.
     */
    function checkKeeperFlow(bytes32 reason, bytes calldata data)
        external
        nonReentrant
        onlyProtectedCaller
        returns (bool ok)
    {
        address vault = msg.sender;

        if (tripped[vault]) {
            // Already tripped: block keeper flows if configured.
            if (config[vault].blockKeeperFlowsWhenTripped) return false;
            return true;
        }

        // Not tripped => ok
        // (You can extend with more pre-conditions later if needed.)
        reason;
        data;
        return true;
    }

    /**
     * @notice Post-hook for SFVault::withdrawFromStrategy anomaly detection.
     * @dev If withdrawn << requested, trip + pause.
     *
     * IMPORTANT: Caller must NOT revert afterward if you want pause to persist.
     */
    function reportWithdrawFromStrategy(uint256 requestedAssets, uint256 withdrawnAssets, bytes32 bundleHash)
        external
        nonReentrant
        onlyProtectedCaller
        returns (bool ok)
    {
        GuardConfig memory cfg = config[msg.sender];
        ok = true;

        if (cfg.minStrategyUnwindBps == 0) {
            return true;
        }

        // withdrawnAssets * 10000 < requestedAssets * minBps => anomaly
        if (requestedAssets > 0) {
            if (withdrawnAssets * 10_000 < requestedAssets * uint256(cfg.minStrategyUnwindBps)) {
                _tripAndPause(
                    msg.sender, "STRATEGY_UNWIND_ANOMALY", abi.encode(requestedAssets, withdrawnAssets, bundleHash)
                );
                ok = false;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        QUEUEING & EXECUTION (PUBLIC)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Queue a withdrawal (share-based). Returns requestId.
     * @dev User must approve this contract to transfer vault shares.
     */
    function requestWithdrawal(address vault, uint256 shares, address receiver)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        GuardConfig memory cfg = config[vault];
        require(cfg.enabled, SFAndIFCircuitBreaker__NotProtected());
        require(shares > 0 && shares <= type(uint128).max, SFAndIFCircuitBreaker__InvalidRequest());

        // Transfer shares into escrow (this contract). This replaces "lockedShares" in-vault.
        if (!IERC20(vault).transferFrom(msg.sender, address(this), shares)) {
            revert SFAndIFCircuitBreaker__TransferFailed();
        }

        uint256 assetsEst = IERC4626(vault).previewRedeem(shares);

        bool needsApproval = (cfg.approvalThresholdAssets > 0 && assetsEst >= cfg.approvalThresholdAssets);

        uint64 delay = 0;
        if (cfg.globalWithdrawTimelockEnabled) {
            delay = cfg.globalWithdrawTimelockDelay;
        } else if (cfg.timelockThresholdAssets > 0 && assetsEst >= cfg.timelockThresholdAssets) {
            delay = cfg.timelockDelay;
        } else {
            // If neither global mode nor threshold requires queueing, queuing is still allowed,
            // but unlockTime will be immediate.
            delay = 0;
        }

        uint64 unlockTime = uint64(block.timestamp) + delay;

        requestId = nextRequestId++;
        withdrawalRequests[requestId] = WithdrawalRequest({
            vault: vault,
            owner: msg.sender,
            receiver: receiver,
            shares: uint128(shares),
            unlockTime: unlockTime,
            needsApproval: needsApproval,
            approved: !needsApproval,
            executed: false,
            cancelled: false
        });

        emit WithdrawalRequested(requestId, vault, msg.sender, receiver, shares, unlockTime, needsApproval);
    }

    /**
     * @notice Cancel a queued withdrawal (only owner, only if not executed/cancelled).
     */
    function cancelWithdrawalRequest(uint256 requestId) external nonReentrant {
        WithdrawalRequest storage r = withdrawalRequests[requestId];

        if (r.owner == address(0)) revert SFAndIFCircuitBreaker__InvalidRequest();
        if (r.executed || r.cancelled) revert SFAndIFCircuitBreaker__InvalidRequest();
        if (msg.sender != r.owner) revert SFAndIFCircuitBreaker__NotAuthorizedCaller();

        r.cancelled = true;

        // Return escrowed shares
        if (!IERC20(r.vault).transfer(r.owner, r.shares)) {
            revert SFAndIFCircuitBreaker__TransferFailed();
        }

        emit WithdrawalCancelled(requestId, r.vault, r.owner);
    }

    /**
     * @notice Approve a queued withdrawal (role-gated).
     */
    function approveWithdrawalRequest(uint256 requestId) external nonReentrant onlyRole(Roles.OPERATOR) {
        WithdrawalRequest storage r = withdrawalRequests[requestId];

        if (r.owner == address(0)) revert SFAndIFCircuitBreaker__InvalidRequest();
        if (r.executed || r.cancelled) revert SFAndIFCircuitBreaker__InvalidRequest();
        if (!r.needsApproval) revert SFAndIFCircuitBreaker__InvalidRequest();

        r.approved = true;

        emit WithdrawalApproved(requestId, r.vault, msg.sender);
    }

    /**
     * @notice Execute a queued withdrawal after timelock + approval. Anyone may execute.
     * @dev Redeems escrowed shares at execution-time exchange rate.
     */
    function executeWithdrawalRequest(uint256 requestId) external nonReentrant returns (uint256 assetsOut) {
        WithdrawalRequest storage r = withdrawalRequests[requestId];

        if (r.owner == address(0)) revert SFAndIFCircuitBreaker__InvalidRequest();
        if (r.executed || r.cancelled) revert SFAndIFCircuitBreaker__InvalidRequest();

        if (block.timestamp < r.unlockTime) revert SFAndIFCircuitBreaker__NotUnlocked();
        if (r.needsApproval && !r.approved) revert SFAndIFCircuitBreaker__NotApproved();

        // Enforce rate limits at execution time (assets determined at execution time)
        uint256 assetsEst = IERC4626(r.vault).previewRedeem(r.shares);
        _consumeRateLimit(r.vault, r.owner, assetsEst);

        r.executed = true;

        // Redeem shares owned by this contract (escrow) and send assets to receiver.
        assetsOut = IERC4626(r.vault).redeem(uint256(r.shares), r.receiver, address(this));

        emit WithdrawalExecuted(requestId, r.vault, msg.sender, assetsOut);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function isWithdrawalRateLimited(address vault, address owner, uint256 assets)
        external
        view
        returns (bool globalLimited, bool userLimited)
    {
        GuardConfig memory cfg = config[vault];

        if (!cfg.enabled) return (false, false);

        if (cfg.globalWithdrawCap24hAssets > 0) {
            Window memory gw = _viewSyncedWindow(globalWindow[vault]);
            globalLimited = (gw.withdrawn + assets > cfg.globalWithdrawCap24hAssets);
        }

        if (cfg.userWithdrawCap24hAssets > 0) {
            Window memory uw = _viewSyncedWindow(userWindow[vault][owner]);
            userLimited = (uw.withdrawn + assets > cfg.userWithdrawCap24hAssets);
        }
    }

    function getWithdrawalRequest(uint256 requestId) external view returns (WithdrawalRequest memory) {
        return withdrawalRequests[requestId];
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Enforces whether a withdrawal can proceed instantly or must be queued.
     * @dev This function is intended to be called from instant execution paths (e.g., ERC4626 `withdraw`
     * and `redeem`), where there is no opportunity to perform multi-step flows like timelocks or
     * manual approvals.
     * @dev Queueing is required when:
     *  - Global withdrawal timelock mode is enabled (all withdrawals must be queued), OR
     *  - `assets >= timelockThresholdAssets` (threshold timelock), OR
     *  - `assets >= approvalThresholdAssets` (withdrawal requires an explicit approval step).
     * @param vault The protected vault address (also the ERC4626 share token).
     * @param assets The withdrawal amount expressed in underlying asset units.
     */
    function _enforceOrQueue(
        address vault,
        /*address owner, The owner of the shares being withdrawn/redeemed (reserved for future per-owner policies)*/
        uint256 assets
    )
        internal
        view
    {
        GuardConfig memory cfg = config[vault];

        // Global timelock mode: force ALL withdrawals into the queue flow.
        require(!cfg.globalWithdrawTimelockEnabled, SFAndIFCircuitBreaker__WithdrawalRequiresQueue());

        // Threshold timelock: force withdrawals >= threshold into the queue flow.
        require(
            cfg.timelockThresholdAssets <= 0 && assets < cfg.timelockThresholdAssets,
            SFAndIFCircuitBreaker__WithdrawalRequiresQueue()
        );

        // Approval threshold: if an approval is required, the instant path cannot satisfy it.
        require(
            cfg.approvalThresholdAssets <= 0 && assets < cfg.approvalThresholdAssets,
            SFAndIFCircuitBreaker__WithdrawalRequiresQueue()
        );
    }

    function _consumeRateLimit(address vault, address owner, uint256 assets) internal {
        GuardConfig memory cfg = config[vault];

        // Global window
        if (cfg.globalWithdrawCap24hAssets > 0) {
            Window storage gw = globalWindow[vault];
            _syncWindow(gw);

            if (gw.withdrawn + assets > cfg.globalWithdrawCap24hAssets) {
                revert SFAndIFCircuitBreaker__RateLimitExceeded();
            }
            gw.withdrawn += assets;
        }

        // Per-user window
        if (cfg.userWithdrawCap24hAssets > 0) {
            Window storage uw = userWindow[vault][owner];
            _syncWindow(uw);

            if (uw.withdrawn + assets > cfg.userWithdrawCap24hAssets) {
                revert SFAndIFCircuitBreaker__RateLimitExceeded();
            }
            uw.withdrawn += assets;
        }
    }

    function _syncWindow(Window storage w) internal {
        // Reset when first used or window expired.
        if (w.start == 0 || block.timestamp - uint256(w.start) >= 1 days) {
            w.start = uint64(block.timestamp);
            w.withdrawn = 0;
        }
    }

    function _viewSyncedWindow(Window memory w) internal view returns (Window memory) {
        if (w.start == 0 || block.timestamp - uint256(w.start) >= 1 days) {
            w.start = uint64(block.timestamp);
            w.withdrawn = 0;
        }
        return w;
    }

    function _tripAndPause(address vault, bytes32 reason, bytes memory data) internal {
        tripped[vault] = true;
        emit CircuitBreakerTripped(vault, reason, data);

        // Attempt to pause the vault/target.
        // NOTE: This contract must hold Roles.PAUSE_GUARDIAN in AddressManager for pause() to succeed.
        (bool success, bytes memory returndata) = vault.call(abi.encodeWithSignature("pause()"));
        emit PauseAttempt(vault, success, returndata);
    }

    /*//////////////////////////////////////////////////////////////
                           UUPS AUTHORIZATION
    //////////////////////////////////////////////////////////////*/

    /// @dev required by the OZ UUPS module.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.OPERATOR) {}
}
