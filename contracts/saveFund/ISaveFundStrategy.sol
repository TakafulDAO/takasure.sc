pragma solidity 0.8.28;

// Minimum functions will need from any strategy.
interface ISaveFundStrategy {
    event OnStrategyLossReported(uint256 previousAssets, uint256 newAssets, uint256 lossAmount, bytes32 reason);

    /*//////////////////////////////////////////////////////////////
                        TO BE CALLED FROM VAULT
    //////////////////////////////////////////////////////////////*/

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
                            CALLED BY ALGOS
    //////////////////////////////////////////////////////////////*/
    // todo: in future use only one file for this ISaveFundStrategyMaintenance
    /// @notice Realize fees, claim rewards, maybe swap them back to USDC, and reinvest.
    // todo: remember to add this access restriction in implementation. onlyKeeper or onlyGovernance or something like that
    function harvest(bytes calldata data) external;

    /// @notice Adjust the position: move range, change liquidity distribution, or change target ratios.
    // todo: remember to add this access restriction in implementation. onlyKeeper or onlyGovernance or something like that
    function rebalance(bytes calldata data) external;

    /*//////////////////////////////////////////////////////////////
                             FOR DEBUGGING
    //////////////////////////////////////////////////////////////*/
    // todo: in future use only one file for this ISaveFundStrategyView

    struct StrategyConfig {
        address asset; // USDC
        address vault;
        address keeper;
        address pool; // e.g. Uniswap v3/v4 pool
        uint256 maxTVL;
        bool paused;
        // optional: strategy type enum, fee params, slippage limits, etc.
    }

    function getConfig() external view returns (StrategyConfig memory);

    /// @notice Idle asset (USDC) held by this strategy.
    function idleAssets() external view returns (uint256);

    /// @notice Value of the active position in USDC (totalAssets - idleAssets).
    function positionValue() external view returns (uint256);

    /// @notice Implementation-specific introspection, e.g. Uniswap ticks, liquidity
    /// Could be overridden in child strategies with more detailed info.
    function getPositionDetails() external view returns (bytes memory);

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set/change keeper.
    // todo: remember to add this access control in implementation onlyGovernance
    // Note: Should be virtual when I write the implementation.
    function setKeeper(address newKeeper) external;

    /// @notice Update per-strategy caps or risk limits.
    // todo: remember to add this access control in implementation onlyGovernance
    // Note: Should be virtual when I write the implementation.
    function setMaxTVL(uint256 newMaxTVL) external;

    /// @notice Update core config like pool / router / price source.
    // todo: remember to add this access control in implementation onlyGovernance
    // Note: Should be virtual when I write the implementation.
    function setConfig(bytes calldata newConfig) external;
}

