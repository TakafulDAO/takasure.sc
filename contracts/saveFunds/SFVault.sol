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

    ISFStrategy public aggregator; // the vault uses as strategy an aggregator to manage different sub-strategies for the underlying assets
    IAddressManager private addressManager;

    EnumerableSet.AddressSet private whitelistedTokens;
    EnumerableSet.AddressSet private validMembers;

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
    event OnAggregatorUpdated(address indexed newAggregator);
    event OnFeeConfigUpdated(uint16 managementFeeBPS, uint16 performanceFeeBPS, uint16 performanceFeeHurdleBPS);
    event OnFeesTaken(uint256 feeAssets, FeeType feeType);

    error SFVault__NotAuthorizedCaller();
    error SFVault__InvalidToken();
    error SFVault__TokenAlreadyWhitelisted();
    error SFVault__InvalidCapBPS();
    error SFVault__TokenNotWhitelisted();
    error SFVault__InvalidFeeBPS();
    error SFVault__NotAddressZero();
    error SFVault__NotAMember();
    error SFVault__ZeroAssets();
    error SFVault__ExceedsMaxDeposit();
    error SFVault__ZeroShares();
    error SFVault__InvalidStrategy();
    error SFVault__StrategyNotSet();
    error SFVault__InsufficientIdleAssets();
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
     * @notice Initialize the vault and its ERC4626 share token.
     * @dev Can only be called once (initializer). Sets AddressManager, initial caps/fees, and whitelists the underlying asset.
     * @param _addressManager Address manager used for role checks and protocol address lookups.
     * @param _underlying Underlying ERC20 asset used for ERC4626 accounting (e.g., USDC).
     * @param _name ERC20 name for the vault share token.
     * @param _symbol ERC20 symbol for the vault share token.
     * @custom:invariant After initialization, the underlying asset is whitelisted with a hard cap of MAX_BPS.
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

    /// @notice Accept ERC721 safe transfers to this vault.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update the vault's global TVL cap.
     * @dev `newCap` is denominated in underlying units. Set to 0 to disable the cap (unlimited).
     * @param newCap New cap for total managed assets (idle + strategy).
     * @custom:invariant If TVLCap != 0, then totalAssets() is intended to remain <= TVLCap after user deposits (subject to rounding and external strategy behavior).
     */
    function setTVLCap(uint256 newCap) external onlyRole(Roles.OPERATOR) {
        uint256 oldCap = TVLCap;
        TVLCap = newCap;
        emit OnTVLCapUpdated(oldCap, newCap);
    }

    /**
     * @notice Add an ERC20 token to the whitelist with the default hard cap (100%).
     * @dev Intended for governance / operator configuration. Reverts for zero address or if already whitelisted.
     * @param token ERC20 token address to whitelist.
     * @custom:invariant If the call succeeds, whitelistedTokens.contains(token) is true and tokenHardCapBPS[token] <= MAX_BPS.
     */
    function whitelistToken(address token) external onlyRole(Roles.OPERATOR) {
        require(token != address(0), SFVault__InvalidToken());
        require(!whitelistedTokens.contains(token), SFVault__TokenAlreadyWhitelisted());

        whitelistedTokens.add(token);
        tokenHardCapBPS[token] = uint16(MAX_BPS);

        emit OnTokenWhitelisted(token, uint16(MAX_BPS));
    }

    /**
     * @notice Add an ERC20 token to the whitelist with a custom allocation hard cap.
     * @dev `hardCapBPS` must be <= MAX_BPS. A hard cap of 0 is allowed.
     * @param token ERC20 token address to whitelist.
     * @param hardCapBPS Maximum allocation for `token` in basis points of total portfolio value.
     * @custom:invariant If the call succeeds, tokenHardCapBPS[token] == hardCapBPS and whitelistedTokens.contains(token) is true.
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
     * @notice Remove an ERC20 token from the whitelist.
     * @dev Removing a token does not prevent the vault/strategy from temporarily holding it while unwinding or swapping.
     * @param token ERC20 token address to remove.
     * @custom:invariant If the call succeeds, whitelistedTokens.contains(token) is false.
     */
    function removeTokenFromWhitelist(address token) external onlyRole(Roles.OPERATOR) {
        require(whitelistedTokens.contains(token), SFVault__TokenNotWhitelisted());

        whitelistedTokens.remove(token);
        emit OnTokenRemovedFromWhitelist(token);
    }

    /**
     * @notice Update a whitelisted token's allocation hard cap.
     * @dev A hard cap of 0 is allowed. Reverts if the token is not currently whitelisted or if `newCapBPS` > MAX_BPS.
     * @param token Whitelisted ERC20 token whose cap is being updated.
     * @param newCapBPS New hard cap in basis points of total portfolio value.
     * @custom:invariant tokenHardCapBPS[token] is always intended to be <= MAX_BPS for whitelisted tokens.
     */
    function setTokenHardCap(address token, uint16 newCapBPS) external onlyRole(Roles.OPERATOR) {
        require(whitelistedTokens.contains(token), SFVault__TokenNotWhitelisted());
        require(newCapBPS <= MAX_BPS, SFVault__InvalidCapBPS());

        uint16 old = tokenHardCapBPS[token];
        tokenHardCapBPS[token] = newCapBPS;
        emit OnTokenHardCapUpdated(token, old, newCapBPS);
    }

    /**
     * @notice Set or change the active aggregator contract used by the vault.
     * @dev Setting the aggregator to address(0) disables aggregator invest/withdraw operations.
     * @param newAggregator New aggregator contract implementing {ISFStrategy}.
     * @custom:invariant After the call, `aggregator` equals `newAggregator`.
     */
    function setAggregator(ISFStrategy newAggregator) external onlyRole(Roles.OPERATOR) {
        aggregator = newAggregator;
        emit OnAggregatorUpdated(address(newAggregator));
    }

    /**
     * @notice Configure management and performance fee parameters.
     * @dev Management fees are charged on {deposit}/{mint}. Performance fees are charged via {takeFees} using a high-water mark and optional APY hurdle.
     * @param _managementFeeBPS Management fee charged on deposits/mints in basis points (must be < MAX_BPS).
     * @param _performanceFeeBPS Performance fee charged on feeable profits in basis points (must be <= MAX_BPS).
     * @param _performanceFeeHurdleBPS Optional APY hurdle in basis points (must be <= MAX_BPS).
     * @custom:invariant managementFeeBPS < MAX_BPS and performanceFeeBPS/performanceFeeHurdleBPS <= MAX_BPS are enforced.
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
     * @notice Set or clear an operator approval on an ERC721 contract for NFTs owned by this vault.
     * @dev Useful for granting strategies permission to manage Uniswap V3 position NFTs held by the vault (e.g., NonfungiblePositionManager).
     * @param nft ERC721 contract address.
     * @param operator Address to grant/revoke approval.
     * @param approved True to approve, false to revoke.
     * @custom:invariant This function does not change vault accounting; it only updates ERC721 approvals.
     */
    function setERC721ApprovalForAll(address nft, address operator, bool approved) external onlyRole(Roles.OPERATOR) {
        IERC721(nft).setApprovalForAll(operator, approved);
    }

    /**
     * @notice Register a protocol member.
     * @param newMember Member to register.
     * @custom:invariant After the call, `validMembers.contains(newMember)` equals `true`.
     */
    function registerMember(address newMember) external onlyRole(Roles.BACKEND_ADMIN) {
        require(newMember != address(0), SFVault__NotAddressZero());
        validMembers.add(newMember);
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
     * @notice Charge and transfer performance fees (in underlying) to the configured fee recipient.
     * @dev Management fees are charged at {deposit}/{mint} time. Performance fees are computed using a high-water mark on assets-per-share and an optional APY hurdle.
     * @return managementFeeAssets Assets taken as management fee (always 0 in this function).
     * @return performanceFeeAssets Assets taken as performance fee and transferred to the fee recipient.
     * @custom:invariant After a successful non-zero fee charge, `lastReport` is updated to block.timestamp and `highWaterMark` is updated to post-fee assets/share.
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
     * @notice Deposit `assets` of underlying into the vault and mint shares to `receiver`.
     * @dev Overrides ERC4626 deposit to apply a management fee on the deposited assets. Shares are minted based on the net assets retained by the vault.
     * @param assets Gross amount of underlying to transfer from the caller (includes any management fee portion).
     * @param receiver Address that will receive the newly minted shares and be credited for deposit accounting.
     * @return shares Amount of shares minted to `receiver`.
     * @custom:invariant Shares are non-transferable: only mint/burn is permitted by {_update}.
     * @custom:invariant Only members can be `receiver`
     */
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        require(validMembers.contains(receiver), SFVault__NotAMember());
        require(assets > 0, SFVault__ZeroAssets());
        require(assets <= maxDeposit(receiver), SFVault__ExceedsMaxDeposit());

        address caller = _msgSender();
        address feeRecipient = addressManager.getProtocolAddressByName("ADMIN__SF_FEE_RECEIVER").addr;

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
     * @notice Mint `shares` to `receiver` by transferring the required amount of underlying (plus any management fee).
     * @dev Overrides ERC4626 mint to avoid bypassing the management fee. The vault computes the net assets needed for `shares` and then charges the fee on top.
     * @param shares Amount of shares to mint.
     * @param receiver Address that will receive the newly minted shares and be credited for deposit accounting.
     * @return assets Gross amount of underlying transferred from the caller (includes any management fee portion).
     * @custom:invariant If a fee recipient is configured, minted shares correspond to `super.previewMint(shares)` net assets remaining in the vault after fee transfer (subject to rounding).
     * @custom:invariant Only members can be `receiver`
     */
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        require(validMembers.contains(receiver), SFVault__NotAMember());
        require(shares > 0, SFVault__ZeroShares());

        address caller = _msgSender();
        address feeRecipient = addressManager.getProtocolAddressByName("ADMIN__SF_FEE_RECEIVER").addr;

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

    /**
     * @notice Move idle underlying into the configured strategy using an aggregator bundle.
     * @dev Callable only by an account with the KEEPER or OPERATOR role. Transfers `assets` to the strategy before calling `strategy.deposit`.
     * @param assets Amount of underlying to invest from idle funds.
     * @param strategies List of sub-strategy addresses for the aggregator to use.
     * @param payloads ABI-encoded, per-sub-strategy call data. The vault encodes `abi.encode(strategies, payloads)` and forwards it to `strategy.deposit`.
     * @return investedAssets Amount of assets reported by the strategy as invested.
     * @custom:invariant This function MUST NOT invest more than `idleAssets()` (enforced by a pre-check).
     */
    function investIntoStrategy(uint256 assets, address[] calldata strategies, bytes[] calldata payloads)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 investedAssets)
    {
        _onlyKeeperOrOperator();
        ISFStrategy strat = aggregator;
        require(address(strat) != address(0), SFVault__StrategyNotSet());
        require(assets > 0, SFVault__ZeroAssets());

        uint256 idle = idleAssets();
        require(assets <= idle, SFVault__InsufficientIdleAssets());

        // Send funds first (aggregator expects to already hold underlying)
        IERC20(asset()).safeTransfer(address(strat), assets);

        // Vault builds the aggregator bundle
        bytes memory data = abi.encode(strategies, payloads);

        investedAssets = strat.deposit(assets, data);
    }

    /**
     * @notice Request underlying to be withdrawn from the configured strategy back to the vault using an aggregator bundle.
     * @dev Callable only by an account with the KEEPER or OPERATOR role. The strategy is expected to transfer withdrawn underlying to this vault.
     * @param assets Amount of underlying to request from the strategy.
     * @param strategies List of sub-strategy addresses for the aggregator to use.
     * @param payloads ABI-encoded, per-sub-strategy call data. The vault encodes `abi.encode(strategies, payloads)` and forwards it to `strategy.withdraw`.
     * @return withdrawnAssets Amount of assets reported by the strategy as withdrawn.
     * @custom:invariant On success, the strategy SHOULD deliver withdrawn underlying to this vault (strategy-defined behavior).
     */
    function withdrawFromStrategy(uint256 assets, address[] calldata strategies, bytes[] calldata payloads)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 withdrawnAssets)
    {
        _onlyKeeperOrOperator();
        ISFStrategy strat = aggregator;
        require(address(strat) != address(0), SFVault__StrategyNotSet());
        require(assets > 0, SFVault__ZeroAssets());

        bytes memory data = abi.encode(strategies, payloads);

        withdrawnAssets = strat.withdraw(assets, address(this), data);
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
     * @notice Return the maximum amount of underlying that can be deposited for `receiver`, enforcing a global TVL cap.
     * @dev If `TVLCap` is 0, this defers to the ERC4626 implementation. If a management fee is enabled, this returns the *gross* maximum such that the net assets retained do not exceed remaining capacity.
     * @param receiver Deposit receiver (ERC4626 parameter; not used for per-user caps).
     * @return maxAssets Maximum gross amount of underlying that can be deposited.
     * @custom:invariant If TVLCap != 0, depositing more than this value should not be possible via {deposit}/{mint} (subject to rounding).
     */
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (!validMembers.contains(receiver)) return 0;
        if (TVLCap == 0) return super.maxDeposit(receiver);

        uint256 remainingNetAssets = _remainingTVLCapacity();

        // If management fee is enabled, the user transfers more than what remains in the vault
        // because a portion is paid out to the fee recipient.
        address feeRecipient = addressManager.getProtocolAddressByName("ADMIN__SF_FEE_RECEIVER").addr;
        if (managementFeeBPS == 0 || feeRecipient == address(0)) return remainingNetAssets;

        // grossAssets = remainingNetAssets * MAX_BPS / (MAX_BPS - feeBPS)
        // Round down to ensure net does not exceed the cap.
        uint256 denom = (MAX_BPS - managementFeeBPS);
        return Math.mulDiv(remainingNetAssets, MAX_BPS, denom);
    }

    /**
     * @notice Return the maximum shares that can be minted for `receiver`, enforcing a global TVL cap.
     * @dev Derived from {maxDeposit} and {previewDeposit}, so it reflects management-fee logic and current exchange rate.
     * @param receiver Mint receiver (ERC4626 parameter; not used for per-user caps).
     * @return maxShares Maximum number of shares mintable.
     * @custom:invariant previewMint(maxShares) is intended to be <= maxDeposit(receiver) (subject to rounding).
     */
    function maxMint(address receiver) public view override returns (uint256) {
        if (!validMembers.contains(receiver)) return 0;
        uint256 maxAssets = maxDeposit(receiver);
        return previewDeposit(maxAssets);
    }

    /**
     * @notice Return the amount of idle underlying held directly by the vault.
     * @dev This is the ERC20 balance of the underlying asset held by this contract (not invested in the strategy).
     * @return Idle underlying balance of the vault.
     * @custom:invariant totalAssets() == idleAssets() + strategyAssets() (assuming the strategy reports accurately).
     */
    function idleAssets() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /**
     * @notice Return the amount of idle underlying held directly by the vault.
     * @dev Convenience wrapper for {idleAssets} to satisfy the {ISFVault} interface.
     * @return Idle underlying balance of the vault.
     * @custom:invariant This function MUST return the same value as {idleAssets}.
     */
    function getIdleAssets() external view override returns (uint256) {
        return idleAssets();
    }

    /**
     * @notice Return the last fee report timestamp and the current total managed assets.
     * @dev `lastReportAssets` is computed live via {totalAssets} and is not an on-chain checkpointed snapshot.
     * @return lastReportTimestamp Timestamp (seconds) when fees were last reported/updated.
     * @return lastReportAssets Current total managed assets at the time of the call.
     * @custom:invariant lastReportTimestamp is always <= block.timestamp.
     */
    function getLastReport() external view override returns (uint256 lastReportTimestamp, uint256 lastReportAssets) {
        return (uint256(lastReport), totalAssets());
    }

    /**
     * @notice Return the fraction of the vault's TVL invested in the aggregator, in basis points.
     * @dev Computed as aggregatorAssets / (idleAssets + aggregatorAssets) scaled by MAX_BPS. Returns 0 if TVL is 0.
     * @return allocationBps Aggregator allocation in basis points (MAX_BPS = 100%).
     * @custom:invariant The return value is always in the range [0, MAX_BPS].
     */
    function getAggregatorAllocation() external view override returns (uint256) {
        uint256 strat = aggregatorAssets(); // single external call into aggregator (if set)
        uint256 tvl = idleAssets() + strat;

        if (tvl == 0) return 0;

        return Math.mulDiv(strat, MAX_BPS, tvl);
    }

    /**
     * @notice Return total assets reported by the configured aggregator.
     * @dev Convenience wrapper for {aggregatorAssets} to satisfy the {ISFVault} interface.
     * @return Assets reported by the aggregator (0 if no aggregator is set).
     * @custom:invariant If `aggregator` is the zero address, this MUST return 0.
     */
    function getAggregatorAssets() external view override returns (uint256) {
        return aggregatorAssets();
    }

    /**
     * @notice Return the current underlying value of `user`'s share balance.
     * @dev Uses ERC4626 conversion via {convertToAssets}. This reflects current share price and does not include historical withdrawals.
     * @param user Account whose position value is being queried.
     * @return Current position value in underlying units.
     * @custom:invariant If `balanceOf(user) == 0`, this MUST return 0.
     */
    function getUserAssets(address user) external view override returns (uint256) {
        uint256 shares = balanceOf(user);
        if (shares == 0) return 0;

        // ERC4626-consistent “position value” in underlying units.
        return convertToAssets(shares);
    }

    /**
     * @notice Return the net deposited amount for `user` as max(totalDeposited - totalWithdrawn, 0).
     * @dev Uses tracked gross deposit/withdraw totals; net deposits cannot be negative and are clamped at 0.
     * @param user Account to query.
     * @return Net deposited amount in underlying units.
     * @custom:invariant The return value is never negative.
     */
    function getUserNetDeposited(address user) external view override returns (uint256) {
        uint256 deposited = getUserTotalDeposited(user);
        uint256 withdrawn = getUserTotalWithdrawn(user);

        // Net deposits can't be negative with uint256; clamp at 0.
        return deposited > withdrawn ? deposited - withdrawn : 0;
    }

    /**
     * @notice Return the total gross deposits attributed to `user`.
     * @dev Updated on {deposit} and {mint}. This value includes any management fee portion paid out on deposit/mint.
     * @param user Account to query.
     * @return Total deposited amount in underlying units (gross).
     * @custom:invariant This value is monotonic non-decreasing for each user.
     */
    function getUserTotalDeposited(address user) public view override returns (uint256) {
        return userTotalDeposited[user];
    }

    /**
     * @notice Return the total withdrawals attributed to `user`.
     * @dev Updated in {_withdraw} on both ERC4626 {withdraw} and {redeem}.
     * @param user Account to query.
     * @return Total withdrawn amount in underlying units.
     * @custom:invariant This value is monotonic non-decreasing for each user.
     */
    function getUserTotalWithdrawn(address user) public view override returns (uint256) {
        return userTotalWithdrawn[user];
    }

    /**
     * @notice Return the profit/loss for `user` as a signed value in underlying units.
     * @dev PnL = currentPositionValue + totalWithdrawn - totalDeposited. The result is saturated to int256 bounds to avoid overflow reverts.
     * @param user Account to query.
     * @return pnl Signed profit/loss in underlying units.
     * @custom:invariant The returned value is always within int256 bounds due to explicit saturation logic.
     */
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

    /**
     * @notice Return the share balance of `user`.
     * @dev Shares are non-transferable: balances change only via mint/burn (deposits/withdrawals).
     * @param user Account to query.
     * @return Share balance of `user`.
     * @custom:invariant This MUST return the same value as {balanceOf(user)}.
     */
    function getUserShares(address user) external view override returns (uint256) {
        return balanceOf(user);
    }

    /**
     * @notice Return vault performance since `timestamp` as a signed basis-points delta based on assets-per-share.
     * @dev If `timestamp == 0`, uses an inception baseline of 1.0 assets/share (1e18). If `timestamp <= lastReport`, uses `highWaterMark` as the baseline.
     *      If `timestamp > lastReport`, returns 0 because no on-chain checkpoint exists for future timestamps.
     * @param timestamp Baseline timestamp (seconds). Use 0 for inception baseline.
     * @return performanceBps Signed performance in BPS where +10_000 represents +100%.
     * @custom:invariant The returned value is within int256 bounds (saturated when necessary).
     */
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

    /**
     * @notice Return the vault's total value locked (TVL) in underlying units.
     * @dev Convenience wrapper for {totalAssets} to satisfy the {ISFVault} interface.
     * @return Total managed assets (idle + strategy) in underlying units.
     * @custom:invariant This MUST return the same value as {totalAssets}.
     */
    function getVaultTVL() external view override returns (uint256) {
        return totalAssets();
    }

    /**
     * @notice Return the total assets invested in the configured aggregator.
     * @dev Returns 0 if no aggregator is set; otherwise delegates to `aggregator.totalAssets()` (external call).
     * @return Assets reported by the aggregator.
     * @custom:invariant If `aggregator` is the zero address, this MUST return 0.
     */
    function aggregatorAssets() public view returns (uint256) {
        if (address(aggregator) == address(0)) return 0;
        return aggregator.totalAssets();
    }

    /**
     * @notice Return the total assets managed by the vault (idle + strategy).
     * @dev Computed as `idleAssets() + aggregatorAssets()`. May revert if the aggregator's `totalAssets()` call reverts.
     * @return Total managed assets in underlying units.
     * @custom:invariant totalAssets() == idleAssets() + aggregatorAssets() (assuming the aggregator reports accurately).
     */
    function totalAssets() public view override returns (uint256) {
        return idleAssets() + aggregatorAssets();
    }

    /**
     * @notice Preview the number of shares minted for a deposit of `assets`, accounting for management fees.
     * @dev If a management fee is enabled and a fee recipient is configured, shares are computed on net assets: `assets - (assets * managementFeeBPS / MAX_BPS)`.
     * @param assets Gross amount of underlying to deposit.
     * @return Shares that would be minted for the deposit.
     * @custom:invariant When fee settings are unchanged, this is consistent with the share amount minted by {deposit} for the same `assets` (subject to rounding).
     */
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        if (assets == 0) return 0;

        address feeRecipient = addressManager.getProtocolAddressByName("ADMIN__SF_FEE_RECEIVER").addr;
        if (managementFeeBPS == 0 || feeRecipient == address(0)) return super.previewDeposit(assets);

        uint256 feeAssets = (assets * managementFeeBPS) / MAX_BPS;
        uint256 netAssets = assets - feeAssets;
        return super.previewDeposit(netAssets);
    }

    /**
     * @notice Preview the gross amount of underlying required to mint `shares`, accounting for management fees.
     * @dev If a management fee is enabled and a fee recipient is configured, this adds a fee on top of the net assets required by ERC4626.
     * @param shares Amount of shares to mint.
     * @return Gross amount of underlying required (includes any management fee portion).
     * @custom:invariant When fee settings are unchanged, this is consistent with the asset amount pulled by {mint} for the same `shares` (subject to rounding).
     */
    function previewMint(uint256 shares) public view override returns (uint256) {
        if (shares == 0) return 0;

        address feeRecipient = addressManager.getProtocolAddressByName("ADMIN__SF_FEE_RECEIVER").addr;
        uint256 netAssets = super.previewMint(shares);

        if (managementFeeBPS == 0 || feeRecipient == address(0)) return netAssets;

        uint256 feeAssets = Math.mulDiv(netAssets, managementFeeBPS, (MAX_BPS - managementFeeBPS), Math.Rounding.Ceil);
        return netAssets + feeAssets;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Compute and collect performance fees (in underlying) based on assets-per-share growth.
     *      Performance fees are charged only when the current assets-per-share is above `highWaterMark` and `performanceFeeBPS` is non-zero.
     *      An optional APY hurdle (`performanceFeeHurdleBPS`) reduces feeable profits based on time elapsed since `lastReport`.
     * @return managementFeeAssets_ Always 0 (management fees are charged on deposit/mint).
     * @return performanceFeeAssets_ Performance fee amount transferred to the fee recipient (0 if none).
     * @custom:invariant After execution, `lastReport` is updated to the current timestamp on all code paths.
     */
    function _chargeFees() internal returns (uint256 managementFeeAssets_, uint256 performanceFeeAssets_) {
        address feeRecipient = addressManager.getProtocolAddressByName("ADMIN__SF_FEE_RECEIVER").addr;
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
     * @dev Calculate remaining TVL capacity under `TVLCap`.
     * @return Remaining TVL capacity in underlying units. Returns type(uint256).max when TVLCap is disabled (0).
     * @custom:invariant If TVLCap == 0, this returns type(uint256).max; otherwise it returns max(TVLCap - totalAssets(), 0).
     */
    function _remainingTVLCapacity() internal view returns (uint256) {
        uint256 cap = TVLCap;

        if (cap == 0) return type(uint256).max;

        uint256 assets = totalAssets();
        if (assets >= cap) return 0;
        return cap - assets;
    }

    /**
     * @dev Override ERC20 balance updates to enforce non-transferable shares.
     * @custom:invariant Transfers between two non-zero addresses MUST revert; only mint (from=0) and burn (to=0) are allowed.
     */
    function _update(address from, address to, uint256 value) internal override {
        require(from == address(0) || to == address(0), SFVault__NonTransferableShares());
        super._update(from, to, value);
    }

    /**
     * @dev Hook to track user withdrawals across BOTH ERC4626 {withdraw} and {redeem}.
     * @param caller Address initiating the withdrawal.
     * @param receiver Address receiving underlying assets.
     * @param owner Address whose shares are being burned.
     * @param assets Amount of underlying withdrawn.
     * @param shares Amount of shares burned.
     * @custom:invariant On every successful withdrawal, userTotalWithdrawn[owner] increases by `assets`.
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        super._withdraw(caller, receiver, owner, assets, shares);

        // Attribute withdrawals to the share owner (the account whose shares were burned)
        userTotalWithdrawn[owner] += assets;
    }

    function _onlyKeeperOrOperator() internal view {
        require(
            addressManager.hasRole(Roles.KEEPER, msg.sender) || addressManager.hasRole(Roles.OPERATOR, msg.sender),
            SFVault__NotAuthorizedCaller()
        );
    }

    /// @dev required by the OZ UUPS module.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.OPERATOR) {}
}
