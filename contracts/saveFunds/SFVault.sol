// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFVault
 * @author Maikel Ordaz
 * @notice ERC4626 vault implementation for TLD Save Funds
 * @dev Upgradeable contract with UUPS pattern
 */

// todo: access control, maybe write this as a module with the other ones?
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ERC4626Upgradeable,
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract SFVault is Initializable, UUPSUpgradeable, ERC4626Upgradeable {
    using SafeERC20 for IERC20;

    ISFStrategy public strategy; // current strategy handling the underlying assets

    // 0 = no cap
    uint256 public tvlCap;
    uint256 public perUserCap;

    // Fees
    address public feeRecipient; // todo: implement with address manager later, leave it like this for now for cleanliness
    uint16 public managementFeeBps; // annual management fee in basis points e.g., 200 = 2%
    uint16 public performanceFeeBps; // performance fee in basis points e.g., 2000 = 20% of profits
    uint16 public performanceFeeHurdleBps; // APY threshold in basis points, can be 0 for no hurdle

    // Performance tracking
    uint64 public lastReport; // timestamp of the last strategy report
    uint256 public highWaterMark; // assets per share, scaled by 1e18

    enum FeeType {
        MANAGEMENT,
        PERFORMANCE
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/
    uint256 private MAX_BPS = 10_000; // 100% in basis points
    uint256 private constant YEAR = 365 days;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/
    event OnTvlCapUpdated(uint256 newCap);
    event OnPerUserCapUpdated(uint256 newCap);
    event OnStrategyUpdated(address indexed newStrategy);
    event OnFeeConfigUpdated(uint16 managementFeeBps, uint16 performanceFeeBps, uint16 performanceFeeHurdleBps);
    event OnFeesTaken(uint256 feeShares, FeeType feeType);

    error SFVault__NonTransferableShares();
    error SFVault__InvalidFeeBps();

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
    function initialize(IERC20 _underlying, string memory _name, string memory _symbol) external initializer {
        __UUPSUpgradeable_init();
        __ERC4626_init(_underlying);
        __ERC20_init(_name, _symbol);

        // fees off by default
        managementFeeBps = 0;
        performanceFeeBps = 0;
        performanceFeeHurdleBps = 0;

        // ? Ask if we want to set some caps at deployment
        // ? Ask if we want to set an initial strategy at deployment
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set TVL cap for the vault.
     * @param newCap The new TVL cap in underlying asset units.
     * todo: access control
     */
    function setTvlCap(uint256 newCap) external {
        tvlCap = newCap;
        emit OnTvlCapUpdated(newCap);
    }

    /**
     * @notice Set per-user cap.
     * @param newCap The new per-user cap in underlying asset units.
     *  todo: access control
     */
    function setPerUserCap(uint256 newCap) external {
        perUserCap = newCap;
        emit OnPerUserCapUpdated(newCap);
    }

    /**
     * @notice Set or change the strategy contract.
     * @param newStrategy The address of the new strategy contract.
     * todo: access control
     */
    function setStrategy(ISFStrategy newStrategy) external {
        strategy = newStrategy;
        emit OnStrategyUpdated(address(newStrategy));
    }

    /**
     * @notice Set fee configuration.
     * @param _managementFeeBps Annual management fee in basis points.
     * @param _performanceFeeBps Performance fee in basis points.
     * @param _performanceFeeHurdleBps Performance fee hurdle in basis points.
     * todo: access control
     */
    function setFeeConfig(uint16 _managementFeeBps, uint16 _performanceFeeBps, uint16 _performanceFeeHurdleBps)
        external
    {
        require(_managementFeeBps <= MAX_BPS, SFVault__InvalidFeeBps());
        require(_performanceFeeBps <= MAX_BPS, SFVault__InvalidFeeBps());

        managementFeeBps = _managementFeeBps;
        performanceFeeBps = _performanceFeeBps;
        performanceFeeHurdleBps = _performanceFeeHurdleBps;
        emit OnFeeConfigUpdated(_managementFeeBps, _performanceFeeBps, _performanceFeeHurdleBps);
    }

    /*//////////////////////////////////////////////////////////////
                                  FEES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Charge management and performance fees, minting shares to feeRecipient.
     * @return managementFeeShares Shares minted as management fee.
     * @return performanceFeeShares Shares minted as performance fee.
     * todo: access control if you want only keeper/backend to call this, or leave open.
     */
    function takeFees() external returns (uint256 managementFeeShares, uint256 performanceFeeShares) {
        (managementFeeShares, performanceFeeShares) = _chargeFees();
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice maxDeposit override to enforce TVL and per-user caps.
     * @param receiver The address of the user depositing assets.
     * @return The maximum amount of assets that can be deposited by the receiver.
     */
    function maxDeposit(address receiver) public view override returns (uint256) {
        // If both caps are off, use default maxDeposit
        if (tvlCap == 0 && perUserCap == 0) return super.maxDeposit(receiver);

        uint256 tvlRemaining = _remainingTvlCapacity();
        uint256 userRemaining = _remainingUserCapacity(receiver);

        // min betwen both remaining capacities
        return tvlRemaining < userRemaining ? tvlRemaining : userRemaining;
    }

    /**
     * @notice maxMint override to enforce TVL and per-user caps.
     * @param receiver The address of the user minting shares.
     * @return The maximum amount of shares that can be minted by the receiver.
     */
    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        return convertToShares(maxAssets);
    }

    /// @notice Returns the amount of idle assets (underlying tokens not invested in the strategy) in the vault.
    function idleAssets() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
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

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Shares are not transferrable.
    function _update(address from, address to, uint256 value) internal override {
        require(from == address(0) || to == address(0), SFVault__NonTransferableShares());
        super._update(from, to, value);
    }

    /**
     * @notice Calculate remaining TVL capacity.
     * @return The remaining TVL capacity in underlying asset units.
     */
    function _remainingTvlCapacity() internal view returns (uint256) {
        uint256 cap = tvlCap;

        if (cap == 0) return type(uint256).max;

        uint256 assets = totalAssets();
        if (assets >= cap) return 0;
        return cap - assets;
    }

    /**
     * @notice Calculate remaining per-user capacity.
     * @param _user The address of the user.
     * @return The remaining per-user capacity in underlying asset units.
     */
    function _remainingUserCapacity(address _user) internal view returns (uint256) {
        uint256 cap = perUserCap;

        if (cap == 0) return type(uint256).max;

        uint256 userAssets = convertToAssets(balanceOf(_user));
        if (userAssets >= cap) return 0;
        return cap - userAssets;
    }

    /**
     * @notice Internal function to charge management and performance fees.
     * @dev Fees are taken in shares by minting new shares to feeRecipient.
     *      Uses a high-water mark on assets-per-share to avoid charging
     *      performance fees on fresh deposits.
     */
    function _chargeFees() internal returns (uint256 managementFeeShares_, uint256 performanceFeeShares_) {
        if (feeRecipient == address(0)) {
            // Skip fees
            lastReport = uint64(block.timestamp);
            return (0, 0);
        }

        uint256 _totalAssets = totalAssets();
        uint256 _totalShares = totalSupply();
        uint256 _timestamp = block.timestamp;
        uint256 _elapsed = _timestamp - uint256(lastReport);

        // No users/assets, skip fees
        if (_totalShares == 0 || _totalAssets == 0) {
            lastReport = uint64(_timestamp);
            highWaterMark = 0;
            return (0, 0);
        }

        // Management fees in assets
        uint256 _managementFeeAssets;
        if (managementFeeBps > 0 && _elapsed > 0) {
            // Linear pro-rata fee based on time elapsed
            // A * (mgmtFeeBps / 1e4) * (Δt / YEAR)
            _managementFeeAssets = (_totalAssets * managementFeeBps * _elapsed) / (MAX_BPS * YEAR);
        }

        // Performance fees in assets, based on high-water mark
        uint256 _currentAssetsPerShareWad = (_totalAssets * 1e18) / _totalShares;

        // Init high-water mark if it's the first time
        if (highWaterMark == 0) {
            highWaterMark = _currentAssetsPerShareWad;
        }

        uint256 _performanceFeeAssets;

        if (performanceFeeBps > 0 && _currentAssetsPerShareWad > highWaterMark) {
            uint256 _gainPerShareWad = _currentAssetsPerShareWad - highWaterMark;
            // Total profit above high-water mark in assets units
            uint256 _profitAssets = (_gainPerShareWad * _totalShares) / 1e18;

            // Optional APY hurdle
            bool _hurdle = true;
            if (performanceFeeHurdleBps > 0 && _elapsed > 0) {
                // APY ~ (profit / (A - profit? approx A)) * (YEAR / Δt)
                // assets per share to avoid deposit distortion:
                // apyBps = (gain / highWaterMark) * (YEAR / Δt) in bps
                uint256 _apyBps = (_gainPerShareWad * MAX_BPS * YEAR) / (highWaterMark * _elapsed);

                if (_apyBps <= performanceFeeHurdleBps) {
                    _hurdle = false;
                }
            }

            if (_hurdle) {
                _performanceFeeAssets = (_profitAssets * performanceFeeBps) / MAX_BPS;
            }
        }

        // Total fees in assets
        uint256 _totalFeeAssets = _managementFeeAssets + _performanceFeeAssets;

        if (_totalFeeAssets == 0) {
            // No fees to charge
            lastReport = uint64(_timestamp);
            highWaterMark = _currentAssetsPerShareWad;
            return (0, 0);
        }

        // Bound to avoid division by zero
        if (_totalFeeAssets > _totalAssets) {
            _totalFeeAssets = _totalAssets - 1;
        }

        // Fee recipient should get shares equivalent to _totalFeeAssets
        // X / (S + X) = F / A => X =  S * F / (A - F)
        // where X = shares to mint, S = supply, F = _totalFeeAssets, A = assets
        uint256 _feeSharesTotal = (_totalShares * _totalFeeAssets) / (_totalAssets - _totalFeeAssets);
        if (_feeSharesTotal == 0) {
            lastReport = uint64(_timestamp);
            highWaterMark = _currentAssetsPerShareWad;
            return (0, 0);
        }

        // Index each fee type
        if (_managementFeeAssets > 0) {
            managementFeeShares_ = (_feeSharesTotal * _managementFeeAssets) / _totalFeeAssets;
            emit OnFeesTaken(managementFeeShares_, FeeType.MANAGEMENT);
        }

        if (_performanceFeeAssets > 0) {
            performanceFeeShares_ = _feeSharesTotal - managementFeeShares_;
            emit OnFeesTaken(performanceFeeShares_, FeeType.PERFORMANCE);
        }

        _mint(feeRecipient, _feeSharesTotal);

        // Update state
        uint256 _newTotalShares = _totalShares + _feeSharesTotal;
        uint256 _newAssetsPerShareWad = (_totalAssets * 1e18) / _newTotalShares;

        highWaterMark = _newAssetsPerShareWad;
        lastReport = uint64(_timestamp);

        return (managementFeeShares_, performanceFeeShares_);
    }

    ///@dev required by the OZ UUPS module.
    function _authorizeUpgrade(address newImplementation) internal override {}
}
