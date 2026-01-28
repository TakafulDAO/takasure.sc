// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.28;

/**
 * @title SFAndIFCircuitBreaker
 * @author Maikel Ordaz
 * @notice Safe Mode circuit breaker: rolling 24h rate limits + large-withdraw approvals.
 * @dev This contract is meant to be called as a hook by protected vaults (e.g. SFVault, IFVault).
 *
 * Design goals:
 * - Hook-first integration: vault calls into this contract as the first step in withdraw/redeem flows.
 * - If a condition triggers, this contract attempts to pause the vault and returns `proceed=false`
 *   so the vault can short-circuit without reverting (revert would roll back the pause).
 * - Large withdrawals are queued by the vault hook itself. There is no user interaction with this contract.
 * - OPERATOR approves queued withdrawals. Execution is performed by the vault (hooked later).
 */

import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {SFPauseflags} from "contracts/helpers/libraries/flags/SFPauseflags.sol";

contract SFAndIFCircuitBreaker is Initializable, UUPSUpgradeable, ReentrancyGuardTransientUpgradeable {
    IAddressManager private addressManager;

    uint256 public nextRequestId;

    mapping(address vault => GuardConfig) public config;
    mapping(address vault => Window) public globalWindow; // vault => rolling window
    mapping(address vault => mapping(address user => Window)) public userWindow; // vault => user => rolling window
    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;
    mapping(address vault => bool) public tripped; // Whether a vault has been triggered/tripped at least once (informational).
    mapping(address vault => uint256) public pauseFlags; // Flags per vault

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    // TODO: maybe move it to other types later

    // Configuration for a protected vault.
    struct GuardConfig {
        // Rolling 24h window caps (assets). 0 disables the cap.
        uint256 globalWithdrawCap24hAssets;
        uint256 userWithdrawCap24hAssets;

        // Large-withdraw approval threshold (assets). 0 disables approvals.
        uint256 approvalThresholdAssets;

        // Whether the vault is protected/enabled.
        bool enabled;
    }

    // Rolling 24h accumulator window.
    struct Window {
        uint64 start;
        uint256 withdrawn;
    }

    enum RequestKind {
        Withdraw, // request originated from withdraw(assets)
        Redeem // request originated from redeem(shares)
    }

    // Large-withdraw request created by the vault hook.
    // TODO: No timelock in v1. Must be added for the Investment Fund use case in future versions.
    struct WithdrawalRequest {
        address vault;
        address owner;
        address receiver;

        RequestKind kind;

        // What the user attempted at request time:
        uint256 assetsRequested; // for Withdraw: exact; for Redeem: estimated via previewRedeem
        uint256 sharesRequested; // for Redeem: exact; for Withdraw: estimated via previewWithdraw

        // Lifecycle
        uint64 createdAt;
        bool approved;
        bool executed;
        bool cancelled;
    }

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    error SFAndIFCircuitBreaker__NotAuthorizedCaller();
    error SFAndIFCircuitBreaker__NotProtected();
    error SFAndIFCircuitBreaker__InvalidConfig();
    error SFAndIFCircuitBreaker__InvalidRequest();

    event OnGuardsUpdated(address indexed vault, GuardConfig config);
    event OnWindowsReset(address indexed vault, address indexed user);
    event OnWithdrawalQueued(
        uint256 indexed requestId,
        address indexed vault,
        address indexed owner,
        address receiver,
        RequestKind kind,
        uint256 assetsRequested,
        uint256 sharesRequested
    );
    event OnWithdrawalApproved(uint256 indexed requestId, address indexed vault, address indexed operator);
    event OnWithdrawalCancelled(uint256 indexed requestId, address indexed vault, address indexed operator);
    event OnWithdrawalExecuted(uint256 indexed requestId, address indexed vault, uint256 assetsOut);
    event OnCircuitBreakerTriggered(address indexed vault, uint256 indexed flagsAdded, uint256 newFlags, bytes data);
    event OnPauseAttempt(address indexed vault, bool success, bytes returndata);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyRole(bytes32 role) {
        require(addressManager.hasRole(role, msg.sender), SFAndIFCircuitBreaker__NotAuthorizedCaller());
        _;
    }

    // TODO: Try later to read the name from the AddressManager the issue is that the contracts will be like PROTOCOL_*VAULT maybe decouple with assemble?
    modifier onlyProtectedCaller() {
        require(config[msg.sender].enabled, SFAndIFCircuitBreaker__NotProtected());
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
        nextRequestId = 1;
    }

    /*//////////////////////////////////////////////////////////////
                           CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set guard configuration for a protected vault.
     * @param vault The vault to protect.
     * @param globalWithdrawCap24hAssets Rolling 24h global cap (assets). 0 disables.
     * @param userWithdrawCap24hAssets Rolling 24h per-user cap (assets). 0 disables.
     * @param approvalThresholdAssets Large-withdraw approval threshold (assets). 0 disables approvals.
     * @param enabled Whether protection is enabled for this vault.
     */
    function setGuards(
        address vault,
        uint256 globalWithdrawCap24hAssets,
        uint256 userWithdrawCap24hAssets,
        uint256 approvalThresholdAssets,
        bool enabled
    ) external onlyRole(Roles.OPERATOR) {
        require(vault != address(0), SFAndIFCircuitBreaker__InvalidConfig());

        GuardConfig storage cfg = config[vault];
        cfg.globalWithdrawCap24hAssets = globalWithdrawCap24hAssets;
        cfg.userWithdrawCap24hAssets = userWithdrawCap24hAssets;
        cfg.approvalThresholdAssets = approvalThresholdAssets;
        cfg.enabled = enabled;

        emit OnGuardsUpdated(vault, cfg);
    }

    /**
     * @notice Reset rolling window counters.
     * @dev If user is address(0), only global window is reset.
     */
    function resetWindows(address vault, address user) external onlyRole(Roles.OPERATOR) {
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

    function clearPauseFlags(address vault, uint256 flagsToClear) external onlyRole(Roles.OPERATOR) {
        pauseFlags[vault] &= ~flagsToClear;
    }

    function resetPauseFlags(address vault) external onlyRole(Roles.OPERATOR) {
        pauseFlags[vault] = 0;
    }

    /*//////////////////////////////////////////////////////////////
                           HOOKS (VAULT CALLS)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Hook for ERC4626 `withdraw(assets, receiver, owner)`-style flows.
     * @dev Must be called by the protected vault.
     * Behavior:
     * - If rate limit would be exceeded: pauses the vault and returns (false, 0).
     * - If assets exceeds approval threshold: queues a request, pauses the vault, returns (false, requestId). // ? Question to Aisha: Pause? or maybe just queue?
     * - Otherwise: consumes rate limits and returns (true, 0).
     * @param owner Owner of shares being withdrawn (for per-user cap).
     * @param receiver Receiver of assets.
     * @param assets Assets requested to withdraw.
     * @return proceed Whether the vault should proceed with the withdrawal.
     * @return requestId Non-zero if a large-withdraw request was queued.
     */
    function hookWithdraw(address owner, address receiver, uint256 assets)
        external
        nonReentrant
        onlyProtectedCaller
        returns (bool proceed, uint256 requestId)
    {
        GuardConfig memory cfg = config[msg.sender];

        // Large-withdraw path => queue + pause + halt (no revert).
        if (cfg.approvalThresholdAssets > 0 && assets >= cfg.approvalThresholdAssets) {
            uint256 sharesEst = IERC4626(msg.sender).previewWithdraw(assets);
            requestId = _queueRequest(msg.sender, owner, receiver, RequestKind.Withdraw, assets, sharesEst);

            _triggerAndPause(
                msg.sender,
                SFPauseflags.LARGE_WITHDRAW_QUEUED_FLAG,
                abi.encode(owner, receiver, assets, sharesEst, requestId)
            );
            return (false, requestId);
        }

        // Rate limit exceeded => pause + halt.
        if (_wouldExceedRateLimit(msg.sender, owner, assets)) {
            _triggerAndPause(msg.sender, SFPauseflags.RATE_LIMIT_EXCEEDED_FLAG, abi.encode(owner, assets));
            return (false, 0);
        }

        // Allowed => consume and proceed.
        _consumeRateLimit(msg.sender, owner, assets);
        return (true, 0);
    }

    /**
     * @notice Hook for ERC4626 `redeem(shares, receiver, owner)`-style flows.
     * @dev Must be called by the protected vault as the FIRST operation of redeem.
     * Behavior mirrors {hookWithdraw}, using `previewRedeem(shares)` to estimate assets.
     * @param owner Owner of shares being redeemed (for per-user cap).
     * @param receiver Receiver of assets.
     * @param shares Shares requested to redeem.
     * @return proceed Whether the vault should proceed with the redemption.
     * @return requestId Non-zero if a large-withdraw request was queued.
     */
    function hookRedeem(address owner, address receiver, uint256 shares)
        external
        nonReentrant
        onlyProtectedCaller
        returns (bool proceed, uint256 requestId)
    {
        uint256 assetsEst = IERC4626(msg.sender).previewRedeem(shares);
        GuardConfig memory cfg = config[msg.sender];

        // Large-withdraw path => queue + pause + halt.
        if (cfg.approvalThresholdAssets > 0 && assetsEst >= cfg.approvalThresholdAssets) {
            requestId = _queueRequest(msg.sender, owner, receiver, RequestKind.Redeem, assetsEst, shares);

            _triggerAndPause(
                msg.sender,
                SFPauseflags.LARGE_WITHDRAW_QUEUED_FLAG,
                abi.encode(owner, receiver, assetsEst, shares, requestId)
            );
            return (false, requestId);
        }

        // Rate limit exceeded => pause + halt.
        if (_wouldExceedRateLimit(msg.sender, owner, assetsEst)) {
            _triggerAndPause(msg.sender, SFPauseflags.RATE_LIMIT_EXCEEDED_FLAG, abi.encode(owner, assetsEst));
            return (false, 0);
        }

        // Allowed => consume and proceed.
        _consumeRateLimit(msg.sender, owner, assetsEst);
        return (true, 0);
    }

    /**
     * @notice Hook to be called by the vault during operator execution of an approved request.
     * @param requestId The queued request id.
     * @param assetsOut The assets the vault is about to transfer to the receiver.
     * @return proceed Whether the vault should proceed with execution.
     */
    function hookExecuteApproved(uint256 requestId, uint256 assetsOut)
        external
        nonReentrant
        onlyProtectedCaller
        returns (bool proceed)
    {
        WithdrawalRequest storage r = withdrawalRequests[requestId];

        require(r.vault == msg.sender, SFAndIFCircuitBreaker__InvalidRequest());
        if (r.cancelled || r.executed || !r.approved) {
            _triggerAndPause(msg.sender, SFPauseflags.EXECUTE_INVALID_STATE, abi.encode(requestId));
            return false;
        }

        if (_wouldExceedRateLimit(msg.sender, r.owner, assetsOut)) {
            _triggerAndPause(
                msg.sender, SFPauseflags.RATE_LIMIT_EXCEEDED_FLAG, abi.encode(r.owner, assetsOut, requestId)
            );
            return false;
        }

        _consumeRateLimit(msg.sender, r.owner, assetsOut);

        r.executed = true;
        emit OnWithdrawalExecuted(requestId, msg.sender, assetsOut);

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                            OPERATOR ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Approve a queued withdrawal request.
     * @dev Does NOT execute; execution is done by the vault.
     */
    // TODO: Maybe perform best here, the vault is so packed right now.
    function approveWithdrawalRequest(uint256 requestId) external nonReentrant onlyRole(Roles.OPERATOR) {
        WithdrawalRequest storage r = withdrawalRequests[requestId];
        require(r.vault != address(0) && !r.cancelled && !r.executed, SFAndIFCircuitBreaker__InvalidRequest());

        r.approved = true;
        emit OnWithdrawalApproved(requestId, r.vault, msg.sender);
    }

    /**
     * @notice Cancel a queued withdrawal request (operator-only escape hatch).
     */
    function cancelWithdrawalRequest(uint256 requestId) external nonReentrant onlyRole(Roles.OPERATOR) {
        WithdrawalRequest storage r = withdrawalRequests[requestId];
        require(r.vault != address(0) && !r.cancelled && !r.executed, SFAndIFCircuitBreaker__InvalidRequest());

        r.cancelled = true;
        emit OnWithdrawalCancelled(requestId, r.vault, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns whether a given (vault, owner, assets) would exceed the current rolling-window caps.
     */
    function wouldExceedRateLimit(address vault, address owner, uint256 assets)
        external
        view
        returns (bool globalExceeded, bool userExceeded)
    {
        GuardConfig memory cfg = config[vault];
        if (!cfg.enabled) return (false, false);

        if (cfg.globalWithdrawCap24hAssets > 0) {
            Window memory gw = _viewSyncedWindow(globalWindow[vault]);
            globalExceeded = (gw.withdrawn + assets > cfg.globalWithdrawCap24hAssets);
        }

        if (cfg.userWithdrawCap24hAssets > 0) {
            Window memory uw = _viewSyncedWindow(userWindow[vault][owner]);
            userExceeded = (uw.withdrawn + assets > cfg.userWithdrawCap24hAssets);
        }
    }

    /**
     * @notice Returns the current global rolling window state for a vault.
     */
    function getGlobalWindowState(address vault)
        external
        view
        returns (uint64 start, uint256 withdrawn, uint256 cap, uint256 remaining, uint64 resetsAt)
    {
        GuardConfig memory cfg = config[vault];
        Window memory w = _viewSyncedWindow(globalWindow[vault]);

        start = w.start;
        withdrawn = w.withdrawn;
        cap = cfg.globalWithdrawCap24hAssets;

        if (cap == 0) remaining = type(uint256).max;
        else if (withdrawn >= cap) remaining = 0;
        else remaining = cap - withdrawn;

        resetsAt = (w.start == 0) ? 0 : (w.start + uint64(1 days));
    }

    /**
     * @notice Returns the current per-user rolling window state for a vault.
     */
    function getUserWindowState(address vault, address owner)
        external
        view
        returns (uint64 start, uint256 withdrawn, uint256 cap, uint256 remaining, uint64 resetsAt)
    {
        GuardConfig memory cfg = config[vault];
        Window memory w = _viewSyncedWindow(userWindow[vault][owner]);

        start = w.start;
        withdrawn = w.withdrawn;
        cap = cfg.userWithdrawCap24hAssets;

        if (cap == 0) remaining = type(uint256).max;
        else if (withdrawn >= cap) remaining = 0;
        else remaining = cap - withdrawn;

        resetsAt = (w.start == 0) ? 0 : (w.start + uint64(1 days));
    }

    /**
     * @notice Returns whether a given assets amount requires large-withdraw approval for a vault.
     */
    function requiresApproval(address vault, uint256 assets) external view returns (bool) {
        GuardConfig memory cfg = config[vault];
        return cfg.enabled && cfg.approvalThresholdAssets > 0 && assets >= cfg.approvalThresholdAssets;
    }

    function getWithdrawalRequest(uint256 requestId) external view returns (WithdrawalRequest memory) {
        return withdrawalRequests[requestId];
    }

    function isRequestExecutable(uint256 requestId) external view returns (bool) {
        WithdrawalRequest memory r = withdrawalRequests[requestId];
        return (r.vault != address(0) && r.approved && !r.executed && !r.cancelled);
    }

    function hasPauseFlag(address vault, uint256 flag) external view returns (bool) {
        return (pauseFlags[vault] & flag) != 0;
    }

    function getPauseFlags(address vault) external view returns (uint256) {
        return pauseFlags[vault];
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _queueRequest(
        address _vault,
        address _owner,
        address _receiver,
        RequestKind _kind,
        uint256 _assetsRequested,
        uint256 _sharesRequested
    ) internal returns (uint256 requestId_) {
        require(_owner != address(0) && _receiver != address(0), SFAndIFCircuitBreaker__InvalidRequest());

        requestId_ = ++nextRequestId;
        withdrawalRequests[requestId_] = WithdrawalRequest({
            vault: _vault,
            owner: _owner,
            receiver: _receiver,
            kind: _kind,
            assetsRequested: _assetsRequested,
            sharesRequested: _sharesRequested,
            createdAt: uint64(block.timestamp),
            approved: false,
            executed: false,
            cancelled: false
        });

        emit OnWithdrawalQueued(requestId_, _vault, _owner, _receiver, _kind, _assetsRequested, _sharesRequested);
    }

    function _wouldExceedRateLimit(address _vault, address _owner, uint256 _assets) internal view returns (bool) {
        GuardConfig memory _cfg = config[_vault];

        if (_cfg.globalWithdrawCap24hAssets > 0) {
            Window memory _gw = _viewSyncedWindow(globalWindow[_vault]);
            if (_gw.withdrawn + _assets > _cfg.globalWithdrawCap24hAssets) return true;
        }

        if (_cfg.userWithdrawCap24hAssets > 0) {
            Window memory _uw = _viewSyncedWindow(userWindow[_vault][_owner]);
            if (_uw.withdrawn + _assets > _cfg.userWithdrawCap24hAssets) return true;
        }

        return false;
    }

    function _consumeRateLimit(address _vault, address _owner, uint256 _assets) internal {
        GuardConfig memory _cfg = config[_vault];

        if (_cfg.globalWithdrawCap24hAssets > 0) {
            Window storage _gw = globalWindow[_vault];
            _syncWindow(_gw);

            if (_gw.withdrawn + _assets > _cfg.globalWithdrawCap24hAssets) {
                // Do not revert. Trigger + pause and let vault stop.
                _triggerAndPause(_vault, SFPauseflags.RATE_LIMIT_EXCEEDED_FLAG, abi.encode(_owner, _assets));
                return;
            }
            _gw.withdrawn += _assets;
        }

        if (_cfg.userWithdrawCap24hAssets > 0) {
            Window storage _uw = userWindow[_vault][_owner];
            _syncWindow(_uw);
            if (_uw.withdrawn + _assets > _cfg.userWithdrawCap24hAssets) {
                _triggerAndPause(_vault, SFPauseflags.RATE_LIMIT_EXCEEDED_FLAG, abi.encode(_owner, _assets));
                return;
            }
            _uw.withdrawn += _assets;
        }
    }

    function _syncWindow(Window storage _w) internal {
        if (_w.start == 0 || block.timestamp - uint256(_w.start) >= 1 days) {
            _w.start = uint64(block.timestamp);
            _w.withdrawn = 0;
        }
    }

    function _viewSyncedWindow(Window memory _w) internal view returns (Window memory) {
        if (_w.start == 0 || block.timestamp - uint256(_w.start) >= 1 days) {
            _w.start = uint64(block.timestamp);
            _w.withdrawn = 0;
        }
        return _w;
    }

    function _triggerAndPause(address vault, uint256 flagsAdded, bytes memory data) internal {
        tripped[vault] = true;

        uint256 updated = pauseFlags[vault] | flagsAdded;
        pauseFlags[vault] = updated;

        emit OnCircuitBreakerTriggered(vault, flagsAdded, updated, data);

        (bool success, bytes memory returndata) = vault.call(abi.encodeWithSignature("pause()"));
        emit OnPauseAttempt(vault, success, returndata);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.OPERATOR) {}
}
