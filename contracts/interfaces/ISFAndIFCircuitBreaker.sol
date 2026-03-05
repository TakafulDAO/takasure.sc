// SPDX-License-Identifier: GPL-3.0-only
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {GuardConfig, Window, WithdrawalRequest} from "contracts/types/CircuitBreakerTypes.sol";

pragma solidity 0.8.28;

interface ISFAndIFCircuitBreaker {
    function initialize(IAddressManager _addressManager) external;
    function setGuards(
        address vault,
        uint256 globalWithdrawCap24hAssets,
        uint256 userWithdrawCap24hAssets,
        uint256 approvalThresholdAssets,
        bool enabled
    ) external;
    function resetWindows(address vault, address user) external;
    function clearPauseFlags(address vault, uint256 flagsToClear) external;
    function resetPauseFlags(address vault) external;
    function hookWithdraw(address owner, address receiver, uint256 assets)
        external
        returns (bool proceed, uint256 requestId);
    function hookRedeem(address owner, address receiver, uint256 shares)
        external
        returns (bool proceed, uint256 requestId);
    function hookExecuteApproved(uint256 requestId, uint256 assetsOut) external returns (bool proceed);
    function approveWithdrawalRequest(uint256 requestId) external;
    function cancelWithdrawalRequest(uint256 requestId) external;
    function wouldExceedRateLimit(address vault, address owner, uint256 assets)
        external
        view
        returns (bool globalExceeded, bool userExceeded);
    function getGlobalWindowState(address vault)
        external
        view
        returns (uint64 start, uint256 withdrawn, uint256 cap, uint256 remaining, uint64 resetsAt);
    function getUserWindowState(address vault, address owner)
        external
        view
        returns (uint64 start, uint256 withdrawn, uint256 cap, uint256 remaining, uint64 resetsAt);
    function requiresApproval(address vault, uint256 assets) external view returns (bool);
    function getWithdrawalRequest(uint256 requestId) external view returns (WithdrawalRequest memory);
    function isRequestExecutable(uint256 requestId) external view returns (bool);
    function hasPauseFlag(address vault, uint256 flag) external view returns (bool);
    function getPauseFlags(address vault) external view returns (uint256);
}
