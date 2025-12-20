// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFVault
 * @author Maikel Ordaz
 * @notice ERC4626 vault implementation for TLD Save Funds
 * @dev Upgradeable contract with UUPS pattern
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ISFVault} from "contracts/interfaces/saveFunds/ISFVault.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ERC4626Upgradeable,
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {FeeType} from "contracts/types/Cash.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

pragma solidity 0.8.28;

contract SFVault is
    ISFVault,
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    PausableUpgradeable,
    ERC4626Upgradeable
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 private constant MAX_BPS = 10_000; // 100% in basis points
    uint256 private constant YEAR = 365 days;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    ISFStrategy public strategy; // current strategy handling the underlying assets
    IAddressManager public addressManager;

    EnumerableSet.AddressSet private whitelistedTokens;

    // Caps 0 = no cap
    uint256 public TVLCap;

    // Fees
    uint16 public managementFeeBPS; // management fee in basis points e.g., 200 = 2%
    uint16 public performanceFeeBPS; // performance fee in basis points e.g., 2000 = 20% of profits
    uint16 public performanceFeeHurdleBPS; // APY threshold in basis points, can be 0 for no hurdle

    // Performance tracking
    uint64 public lastReport; // timestamp of the last strategy report
    uint256 public highWaterMark; // assets per share, scaled by 1e18

    mapping(address token => uint16 capBPS) public tokenHardCapBPS;
    mapping(address user => uint256 totalDeposited) private userTotalDeposited;
    mapping(address user => uint256 totalWithdrawn) private userTotalWithdrawn;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/
    event OnTokenWhitelisted(address indexed token, uint16 hardCapBPS);
    event OnTVLCapUpdated(uint256 oldCap, uint256 newCap);
    event OnTokenRemovedFromWhitelist(address indexed token);
    event OnTokenHardCapUpdated(address indexed token, uint16 oldCapBPS, uint16 newCapBPS);
    event OnStrategyUpdated(address indexed newStrategy);
    event OnFeeConfigUpdated(uint16 managementFeeBPS, uint16 performanceFeeBPS, uint16 performanceFeeHurdleBPS);
    event OnFeesTaken(uint256 feeAssets, FeeType feeType);

    error SFVault__NotAuthorizedCaller();
    error SFVault__InvalidToken();
    error SFVault__TokenAlreadyWhitelisted();
    error SFVault__InvalidCapBPS();
    error SFVault__TokenNotWhitelisted();
    error SFVault__InvalidFeeBPS();
    error SFVault__ZeroAssets();
    error SFVault__ExceedsMaxDeposit();
    error SFVault__ZeroShares();
    error SFVault__InsufficientUSDCForFees();
    error SFVault__NonTransferableShares();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyRole(bytes32 role) {
        require(addressManager.hasRole(role, msg.sender), SFVault__NotAuthorizedCaller());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param _underlying The underlying asset for the vault. (USDC)
     * @param _name The name of the vault shares token.
     * @param _symbol The symbol of the vault shares token.
     */
    function initialize(IAddressManager _addressManager, IERC20 _underlying, string memory _name, string memory _symbol)
        external
        initializer
    {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        __Pausable_init();
        __ERC4626_init(_underlying);
        __ERC20_init(_name, _symbol);

        addressManager = _addressManager;

        // fees off by default
        managementFeeBPS = 0;
        performanceFeeBPS = 0;
        performanceFeeHurdleBPS = 0;

        TVLCap = 20_000 * 1e6; // 20 thousand USDC

        // Whitelist the underlying (USDC) by default with a 100% hard cap.
        whitelistedTokens.add(address(_underlying));
        tokenHardCapBPS[address(_underlying)] = uint16(MAX_BPS);
        emit OnTokenWhitelisted(address(_underlying), uint16(MAX_BPS));
        // ? Ask if we want to set an initial strategy at deployment
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set TVL cap for the vault.
     * @param newCap The new TVL cap in underlying asset units.
     */
    function setTVLCap(uint256 newCap) external onlyRole(Roles.OPERATOR) {
        uint256 oldCap = TVLCap;
        TVLCap = newCap;
        emit OnTVLCapUpdated(oldCap, newCap);
    }

    /**
     * @notice Add a token to the whitelist (default hard cap = 100%).
     * @dev Intended for governance / Algo Manager configuration.
     */
    function whitelistToken(address token) external onlyRole(Roles.OPERATOR) {
        require(token != address(0), SFVault__InvalidToken());
        require(!whitelistedTokens.contains(token), SFVault__TokenAlreadyWhitelisted());

        whitelistedTokens.add(token);
        tokenHardCapBPS[token] = uint16(MAX_BPS);

        emit OnTokenWhitelisted(token, uint16(MAX_BPS));
    }

    /**
     * @notice Add a token to the whitelist with a custom hard cap.
     * @param token ERC20 token address.
     * @param hardCapBPS Allocation hard cap in BPS of total portfolio value.
     */
    function whitelistTokenWithCap(address token, uint16 hardCapBPS) external onlyRole(Roles.OPERATOR) {
        require(token != address(0), SFVault__InvalidToken());
        require(!whitelistedTokens.contains(token), SFVault__TokenAlreadyWhitelisted());
        require(hardCapBPS <= MAX_BPS, SFVault__InvalidCapBPS());

        whitelistedTokens.add(token);
        tokenHardCapBPS[token] = hardCapBPS;

        emit OnTokenWhitelisted(token, hardCapBPS);
    }

    /**
     * @notice Remove a token from the whitelist.
     * @dev Removing a token does not prevent the vault from temporarily holding it while selling/unwinding.
     */
    function removeTokenFromWhitelist(address token) external onlyRole(Roles.OPERATOR) {
        require(whitelistedTokens.contains(token), SFVault__TokenNotWhitelisted());

        whitelistedTokens.remove(token);
        emit OnTokenRemovedFromWhitelist(token);
    }

    /**
     * @notice Update a token's allocation hard cap.
     * @dev A hard cap of 0 is allowed.
     */
    function setTokenHardCap(address token, uint16 newCapBPS) external onlyRole(Roles.OPERATOR) {
        require(whitelistedTokens.contains(token), SFVault__TokenNotWhitelisted());
        require(newCapBPS <= MAX_BPS, SFVault__InvalidCapBPS());

        uint16 old = tokenHardCapBPS[token];
        tokenHardCapBPS[token] = newCapBPS;
        emit OnTokenHardCapUpdated(token, old, newCapBPS);
    }

    /**
     * @notice Set or change the strategy contract.
     * @param newStrategy The address of the new strategy contract.
     */
    function setStrategy(ISFStrategy newStrategy) external onlyRole(Roles.OPERATOR) {
        strategy = newStrategy;
        emit OnStrategyUpdated(address(newStrategy));
    }

    /**
     * @notice Set fee configuration.
     * @param _managementFeeBPS management fee per deposit in basis points.
     * @param _performanceFeeBPS Performance fee in basis points.
     * @param _performanceFeeHurdleBPS Performance fee hurdle in basis points.
     */
    function setFeeConfig(uint16 _managementFeeBPS, uint16 _performanceFeeBPS, uint16 _performanceFeeHurdleBPS)
        external
        onlyRole(Roles.OPERATOR)
    {
        require(
            _managementFeeBPS < MAX_BPS && _performanceFeeBPS <= MAX_BPS && _performanceFeeHurdleBPS <= MAX_BPS,
            SFVault__InvalidFeeBPS()
        );

        managementFeeBPS = _managementFeeBPS;
        performanceFeeBPS = _performanceFeeBPS;
        performanceFeeHurdleBPS = _performanceFeeHurdleBPS;
        emit OnFeeConfigUpdated(_managementFeeBPS, _performanceFeeBPS, _performanceFeeHurdleBPS);
    }

    /**
     * @notice Set ERC721 approval for all.
     * @param nft The address of the ERC721 contract.
     * @param operator The operator address to set approval for.
     * @param approved Whether to approve or revoke approval.
     * @dev  For Uniswap V3 nft = address(nonfungiblePositionManager), operator = address(SFUniswapV3Strategy)
     *       approved = true
     */
    function setERC721ApprovalForAll(address nft, address operator, bool approved) external onlyRole(Roles.OPERATOR) {
        IERC721(nft).setApprovalForAll(operator, approved);
    }

    /*//////////////////////////////////////////////////////////////
                               EMERGENCY
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyRole(Roles.PAUSE_GUARDIAN) {
        _pause();
    }

    function unpause() external onlyRole(Roles.PAUSE_GUARDIAN) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                                  FEES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Charge performance fees and transfer them in underlying (USDC) to the fee recipient.
     * @dev Management fees are charged at deposit/mint time.
     * @return managementFeeAssets Assets taken as management fee (always 0 here).
     * @return performanceFeeAssets Assets taken as performance fee.
     */
    function takeFees()
        external
        nonReentrant
        onlyRole(Roles.OPERATOR)
        returns (uint256 managementFeeAssets, uint256 performanceFeeAssets)
    {
        (managementFeeAssets, performanceFeeAssets) = _chargeFees();
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSITS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit assets into the vault, applying a management fee on the deposit.
     * @dev The management fee is paid in underlying (USDC) to the fee recipient.
     */
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        require(assets > 0, SFVault__ZeroAssets());
        require(assets <= maxDeposit(receiver), SFVault__ExceedsMaxDeposit());

        address caller = _msgSender();
        address feeRecipient = addressManager.getProtocolAddressByName("SF_VAULT_FEE_RECIPIENT").addr;

        uint256 feeAssets;
        uint256 netAssets = assets;

        if (managementFeeBPS > 0 && feeRecipient != address(0)) {
            feeAssets = (assets * managementFeeBPS) / MAX_BPS;
            netAssets = assets - feeAssets;
        }

        // Compute shares based on the amount that actually stays in the vault
        uint256 userShares = super.previewDeposit(netAssets);
        require(userShares > 0, SFVault__ZeroShares());

        // Pull full amount from user
        IERC20(asset()).safeTransferFrom(caller, address(this), assets);

        // Pay fee in underlying
        if (feeAssets > 0) {
            IERC20(asset()).safeTransfer(feeRecipient, feeAssets);
            emit OnFeesTaken(feeAssets, FeeType.MANAGEMENT);
        }

        // Mint shares to receiver
        _mint(receiver, userShares);

        userTotalDeposited[receiver] += assets;

        emit Deposit(caller, receiver, assets, userShares);

        return userShares;
    }

    /**
     * @notice Mint shares into the vault, applying a management fee on the deposit.
     * @dev Overrides ERC4626 mint to avoid bypassing the management fee.
     *      The management fee is paid in underlying (USDC) to the fee recipient.
     */
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        require(shares > 0, SFVault__ZeroShares());

        address caller = _msgSender();
        address feeRecipient = addressManager.getProtocolAddressByName("SF_VAULT_FEE_RECIPIENT").addr;

        // Net assets required to mint the requested shares (the amount that must stay in the vault)
        uint256 netAssets = super.previewMint(shares);
        require(netAssets > 0, SFVault__ZeroAssets());

        uint256 feeAssets;
        uint256 grossAssets = netAssets;

        if (managementFeeBPS > 0 && feeRecipient != address(0)) {
            // grossAssets = netAssets + feeAssets, where feeAssets is taken from grossAssets
            // netAssets = grossAssets * (MAX_BPS - feeBPS) / MAX_BPS
            // => feeAssets = netAssets * feeBPS / (MAX_BPS - feeBPS)
            feeAssets = Math.mulDiv(netAssets, managementFeeBPS, (MAX_BPS - managementFeeBPS), Math.Rounding.Ceil);
            grossAssets = netAssets + feeAssets;
        }

        require(grossAssets <= maxDeposit(receiver), SFVault__ExceedsMaxDeposit());

        IERC20(asset()).safeTransferFrom(caller, address(this), grossAssets);

        if (feeAssets > 0) {
            IERC20(asset()).safeTransfer(feeRecipient, feeAssets);
            emit OnFeesTaken(feeAssets, FeeType.MANAGEMENT);
        }

        _mint(receiver, shares);
        emit Deposit(caller, receiver, grossAssets, shares);

        userTotalDeposited[receiver] += grossAssets;

        return grossAssets;
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function isTokenWhitelisted(address token) external view returns (bool) {
        return whitelistedTokens.contains(token);
    }

    function whitelistedTokensLength() external view returns (uint256) {
        return whitelistedTokens.length();
    }

    function getWhitelistedTokens() external view returns (address[] memory) {
        return whitelistedTokens.values();
    }

    /**
     * @notice maxDeposit override to enforce a global TVL cap.
     * @param receiver The address of the user depositing assets.
     * @return The maximum amount of assets that can be deposited by the receiver.
     */
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (TVLCap == 0) return super.maxDeposit(receiver);

        uint256 remainingNetAssets = _remainingTVLCapacity();

        // If management fee is enabled, the user transfers more than what remains in the vault
        // because a portion is paid out to the fee recipient.
        address feeRecipient = addressManager.getProtocolAddressByName("SF_VAULT_FEE_RECIPIENT").addr;
        if (managementFeeBPS == 0 || feeRecipient == address(0)) return remainingNetAssets;

        // grossAssets = remainingNetAssets * MAX_BPS / (MAX_BPS - feeBPS)
        // Round down to ensure net does not exceed the cap.
        uint256 denom = (MAX_BPS - managementFeeBPS);
        return Math.mulDiv(remainingNetAssets, MAX_BPS, denom);
    }

    /**
     * @notice maxMint override to enforce a global TVL cap.
     * @param receiver The address of the user minting shares.
     * @return The maximum amount of shares that can be minted by the receiver.
     */
    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        return previewDeposit(maxAssets);
    }

    /// @notice Returns the amount of idle assets (underlying tokens not invested in the strategy) in the vault.
    function idleAssets() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function getIdleAssets() external view override returns (uint256) {
        return idleAssets();
    }

    function getLastReport() external view override returns (uint256 lastReportTimestamp, uint256 lastReportAssets) {
        return (uint256(lastReport), totalAssets());
    }

    /// @dev Returned value is in BPS (10_000 = 100%).
    function getStrategyAllocation() external view override returns (uint256) {
        uint256 strat = strategyAssets(); // single external call into strategy (if set)
        uint256 tvl = idleAssets() + strat;

        if (tvl == 0) return 0;

        return Math.mulDiv(strat, MAX_BPS, tvl);
    }

    function getStrategyAssets() external view override returns (uint256) {
        return strategyAssets();
    }

    function getUserAssets(address user) external view override returns (uint256) {
        uint256 shares = balanceOf(user);
        if (shares == 0) return 0;

        // ERC4626-consistent “position value” in underlying units.
        return convertToAssets(shares);
    }

    function getUserNetDeposited(address user) external view override returns (uint256) {
        uint256 deposited = getUserTotalDeposited(user);
        uint256 withdrawn = getUserTotalWithdrawn(user);

        // Net deposits can't be negative with uint256; clamp at 0.
        return deposited > withdrawn ? deposited - withdrawn : 0;
    }

    function getUserTotalDeposited(address user) public view override returns (uint256) {
        return userTotalDeposited[user];
    }

    function getUserTotalWithdrawn(address user) public view override returns (uint256) {
        return userTotalWithdrawn[user];
    }

    /// @dev PnL is (current position value + totalWithdrawn - totalDeposited).
    function getUserPnL(address user) external view override returns (int256) {
        uint256 shares = balanceOf(user);

        uint256 currentAssets = shares == 0 ? 0 : convertToAssets(shares);
        uint256 deposited = userTotalDeposited[user];
        uint256 withdrawn = userTotalWithdrawn[user];

        // totalValue = currentAssets + withdrawn (unchecked + saturation to avoid revert on overflow)
        uint256 totalValue;
        unchecked {
            totalValue = currentAssets + withdrawn;
            if (totalValue < currentAssets) totalValue = type(uint256).max; // overflow -> saturate
        }

        // pnl = totalValue - deposited (as signed), with saturation to int256 bounds
        if (totalValue >= deposited) {
            uint256 diff = totalValue - deposited;
            if (diff > uint256(type(int256).max)) return type(int256).max;
            return int256(diff);
        } else {
            uint256 diff = deposited - totalValue;
            if (diff > uint256(type(int256).max)) return type(int256).min;
            return -int256(diff);
        }
    }

    function getUserShares(address user) external view override returns (uint256) {
        return balanceOf(user);
    }

    /// @dev Returns signed performance in BPS (10_000 = +100%) based on assets/share.
    function getVaultPerformanceSince(uint256 timestamp) external view override returns (int256) {
        uint256 totalShares = totalSupply();
        if (totalShares == 0) return 0;

        // Current assets/share in WAD
        uint256 currentAssetsPerShareWad = Math.mulDiv(totalAssets(), 1e18, totalShares);

        uint256 baseAssetsPerShareWad;
        if (timestamp == 0) {
            // inception baseline: 1.0 asset/share in WAD
            baseAssetsPerShareWad = 1e18;
        } else if (timestamp <= uint256(lastReport)) {
            // `highWaterMark` is used as the last report baseline in this vault’s fee logic
            baseAssetsPerShareWad = highWaterMark;
        } else {
            // no on-chain historical checkpoint for future timestamps
            return 0;
        }

        if (baseAssetsPerShareWad == 0) return 0;

        // ratio in BPS = current/base * 10_000
        uint256 ratioBps = Math.mulDiv(currentAssetsPerShareWad, MAX_BPS, baseAssetsPerShareWad);

        if (ratioBps >= MAX_BPS) {
            uint256 diff = ratioBps - MAX_BPS;
            if (diff > uint256(type(int256).max)) return type(int256).max;
            return int256(diff);
        } else {
            uint256 diff = MAX_BPS - ratioBps;
            if (diff > uint256(type(int256).max)) return type(int256).min;
            return -int256(diff);
        }
    }

    function getVaultTVL() external view override returns (uint256) {
        return totalAssets();
    }

    /// @notice Returns the total assets invested in the strategy.
    function strategyAssets() public view returns (uint256) {
        if (address(strategy) == address(0)) return 0;
        return strategy.totalAssets();
    }

    /// @notice Returns the total assets managed by the vault (idle + strategy).
    function totalAssets() public view override returns (uint256) {
        return idleAssets() + strategyAssets();
    }

    /**
     * @notice Preview shares a user will receive for a given deposit amount, considering fees.
     * @param assets The amount of underlying assets to deposit.
     * @return The amount of shares the user would receive.
     */
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        if (assets == 0) return 0;

        address feeRecipient = addressManager.getProtocolAddressByName("SF_VAULT_FEE_RECIPIENT").addr;
        if (managementFeeBPS == 0 || feeRecipient == address(0)) return super.previewDeposit(assets);

        uint256 feeAssets = (assets * managementFeeBPS) / MAX_BPS;
        uint256 netAssets = assets - feeAssets;
        return super.previewDeposit(netAssets);
    }

    /**
     * @notice Preview the amount of assets required to mint `shares`, considering the management fee.
     */
    function previewMint(uint256 shares) public view override returns (uint256) {
        if (shares == 0) return 0;

        address feeRecipient = addressManager.getProtocolAddressByName("SF_VAULT_FEE_RECIPIENT").addr;
        uint256 netAssets = super.previewMint(shares);

        if (managementFeeBPS == 0 || feeRecipient == address(0)) return netAssets;

        uint256 feeAssets = Math.mulDiv(netAssets, managementFeeBPS, (MAX_BPS - managementFeeBPS), Math.Rounding.Ceil);
        return netAssets + feeAssets;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to charge performance fees.
     * @dev Transfers performance fees in underlying (USDC) from idle liquidity to the fee recipient.
     *      Uses a high-water mark on assets-per-share to avoid charging performance fees on fresh deposits.
     */
    function _chargeFees() internal returns (uint256 managementFeeAssets_, uint256 performanceFeeAssets_) {
        address feeRecipient = addressManager.getProtocolAddressByName("SF_VAULT_FEE_RECIPIENT").addr;
        if (feeRecipient == address(0)) {
            // Skip fees
            lastReport = uint64(block.timestamp);
            return (0, 0);
        }

        uint256 totalAssets_ = totalAssets();
        uint256 totalShares_ = totalSupply();
        uint256 timestamp_ = block.timestamp;

        // No users/assets, skip fees
        if (totalShares_ == 0 || totalAssets_ == 0) {
            lastReport = uint64(timestamp_);
            highWaterMark = 0;
            return (0, 0);
        }

        uint256 elapsed = timestamp_ - uint256(lastReport);

        // Current assets per share, scaled by 1e18
        uint256 currentAssetsPerShareWad = (totalAssets_ * 1e18) / totalShares_;

        // Init high-water mark if it's the first time
        if (highWaterMark == 0) {
            highWaterMark = currentAssetsPerShareWad;
            lastReport = uint64(timestamp_);
            return (0, 0);
        }

        // Only charge performance fee if above high-water mark
        if (performanceFeeBPS == 0 || currentAssetsPerShareWad <= highWaterMark) {
            lastReport = uint64(timestamp_);
            highWaterMark = currentAssetsPerShareWad;
            return (0, 0);
        }

        uint256 gainPerShareWad = currentAssetsPerShareWad - highWaterMark;
        // Total profit above high-water mark in assets units
        uint256 grossProfitAssets = (gainPerShareWad * totalShares_) / 1e18;

        // Apply APY hurdle if set
        uint256 feeableProfitAssets = grossProfitAssets;
        if (performanceFeeHurdleBPS > 0 && elapsed > 0) {
            uint256 hurdleReturnedAssets = (totalAssets_ * performanceFeeHurdleBPS * elapsed) / (MAX_BPS * YEAR);
            if (grossProfitAssets <= hurdleReturnedAssets) {
                lastReport = uint64(timestamp_);
                highWaterMark = currentAssetsPerShareWad;
                return (0, 0);
            }
            feeableProfitAssets = grossProfitAssets - hurdleReturnedAssets;
        }

        // Actual fee amount in assets
        performanceFeeAssets_ = (feeableProfitAssets * performanceFeeBPS) / MAX_BPS;

        if (performanceFeeAssets_ == 0) {
            lastReport = uint64(timestamp_);
            highWaterMark = currentAssetsPerShareWad;
            return (0, 0);
        }

        // Fees are paid in underlying; require enough idle liquidity.
        require(idleAssets() >= performanceFeeAssets_, SFVault__InsufficientUSDCForFees());

        IERC20(asset()).safeTransfer(feeRecipient, performanceFeeAssets_);
        emit OnFeesTaken(performanceFeeAssets_, FeeType.PERFORMANCE);

        // Update state to post-fee assets/share
        uint256 newTotalAssets = totalAssets_ - performanceFeeAssets_;
        uint256 newAssetsPerShareWad = (newTotalAssets * 1e18) / totalShares_;

        highWaterMark = newAssetsPerShareWad;
        lastReport = uint64(timestamp_);

        managementFeeAssets_ = 0;
        return (0, performanceFeeAssets_);
    }

    /**
     * @notice Calculate remaining TVL capacity.
     * @return The remaining TVL capacity in underlying asset units.
     */
    function _remainingTVLCapacity() internal view returns (uint256) {
        uint256 cap = TVLCap;

        if (cap == 0) return type(uint256).max;

        uint256 assets = totalAssets();
        if (assets >= cap) return 0;
        return cap - assets;
    }

    /// @notice Shares are not transferrable.
    function _update(address from, address to, uint256 value) internal override {
        require(from == address(0) || to == address(0), SFVault__NonTransferableShares());
        super._update(from, to, value);
    }

    /// @dev Track user withdrawals across BOTH withdraw() and redeem()
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        super._withdraw(caller, receiver, owner, assets, shares);

        // Attribute withdrawals to the share owner (the account whose shares were burned)
        userTotalWithdrawn[owner] += assets;
    }

    /// @dev required by the OZ UUPS module.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.OPERATOR) {}
}
