// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

interface ISFStrategy {
    event OnStrategyLossReported(uint256 previousAssets, uint256 newAssets, uint256 lossAmount, bytes32 reason);

    /// @notice Underlying asset managed by this strategy.
    function asset() external view returns (address);

    /// @notice Vault that owns this strategy.
    function vault() external view returns (address);

    /// @notice Total value in underlying asset terms managed by this strategy,
    /// including idle balance inside the strategy + deployed positions.
    function totalAssets() external view returns (uint256);

    /// @notice Max amount of assets the vault is allowed to deposit right now.
    function maxDeposit() external view returns (uint256);

    /// @notice Max amount of assets the vault can pull right now without breaking.
    function maxWithdraw() external view returns (uint256);

    /// @notice Vault sends `assets` USDC here to be deployed into the strategy.
    // todo: remember to add this access restriction in implementation. onlyVault
    /// @return investedAssets actual amount effectively put to work.
    function deposit(uint256 assets, bytes calldata data) external returns (uint256 investedAssets);

    /// @notice Vault asks the strategy to realize `assets` USDC back.
    // todo: remember to add this access restriction in implementation. onlyVault
    /// @param receiver usually the vault, but kept generic for future-proofing.
    /// @return withdrawnAssets actual amount returned (may be <= requested assets if there are losses).
    function withdraw(uint256 assets, address receiver, bytes calldata data) external returns (uint256 withdrawnAssets);

    /*//////////////////////////////////////////////////////////////
                               EMERGENCY
    //////////////////////////////////////////////////////////////*/
    function pause() external;
    function unpause() external;
    function emergencyExit(address receiver) external;

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update per-strategy caps or risk limits.
    // Note: Should be virtual when I write the implementation.
    function setMaxTVL(uint256 newMaxTVL) external;

    /// @notice Update core config like pool / router / price source.
    // Note: Should be virtual when I write the implementation.
    function setConfig(bytes calldata newConfig) external;
}

