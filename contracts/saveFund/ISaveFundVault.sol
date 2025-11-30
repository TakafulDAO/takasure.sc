pragma solidity 0.8.28;

interface ISaveFundVault {
    // From ERC4626 standard
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    function asset() external view returns (address assetTokenAddress);
    function totalAssets() external view returns (uint256 totalManagedAssets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function maxMint(address receiver) external view returns (uint256 maxShares);
    function previewMint(uint256 shares) external view returns (uint256 assets);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function maxRedeem(address owner) external view returns (uint256 maxShares);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    // From ERC20 standard
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);

    // TODO: Additional to implement
    event FeesTaken(uint256 feeRecipient, uint256 feeAssetsOrShares, uint256 feeType);
    event StrategyUpdated(address indexed newStrategy, uint256 newCap, bool active);
    event TVLCapUpdated(uint256 newCap);

    function pause() external;
    function unpause() external;
    function getUserAssets(address user) external view returns (uint256);
    function getUserShares(address user) external view returns (uint256);
    function getUserTotalDeposited(address user) external view returns (uint256);
    function getUserTotalWithdrawn(address user) external view returns (uint256);
    function getUserNetDeposited(address user) external view returns (uint256);
    function getUserPnL(address user) external view returns (int256);
    function getVaultTVL() external view returns (uint256);
    function getIdleAssets() external view returns (uint256);
    function getStrategyAssets() external view returns (uint256);
    function getStrategyAllocation() external view returns (uint256);
    function getVaultPerformanceSince(uint256 timestamp) external view returns (int256);
    function investIntoStrategy(address strategy, uint256 assets) external;
    function withdrawFromStrategy(address strategy, uint256 assets) external;
    function rebalance(address fromStrategy, address toStrategy, uint256 assets) external;
    function harvest(address strategy) external;
}
