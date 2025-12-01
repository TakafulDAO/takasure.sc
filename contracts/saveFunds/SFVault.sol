// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFVault
 * @author Maikel Ordaz
 * @notice ERC4626 vault implementation for TLD Save Funds
 * @dev Upgradeable contract with UUPS pattern
 */

// todo: access control, maybe write this as a module with the other ones?
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ERC4626Upgradeable,
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract SFVault is Initializable, UUPSUpgradeable, ERC4626Upgradeable {
    using SafeERC20 for IERC20;

    // 0 = no cap
    uint256 public tvlCap;
    uint256 public perUserCap;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/
    event OnTvlCapUpdated(uint256 newCap);
    event OnPerUserCapUpdated(uint256 newCap);

    error SFVault__NonTransferableShares();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 _underlying, string memory _name, string memory _symbol) external initializer {
        __UUPSUpgradeable_init();
        __ERC4626_init(_underlying);
        __ERC20_init(_name, _symbol);

        // ? Ask if we want to set some caps at deployment
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    // todo: access control
    function setTvlCap(uint256 newCap) external {
        tvlCap = newCap;
        emit OnTvlCapUpdated(newCap);
    }

    // todo: access control
    function setPerUserCap(uint256 newCap) external {
        perUserCap = newCap;
        emit OnPerUserCapUpdated(newCap);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function maxDeposit(address receiver) public view override returns (uint256) {
        // If both caps are off, use default maxDeposit
        if (tvlCap == 0 && perUserCap == 0) return super.maxDeposit(receiver);

        uint256 tvlRemaining = _remainingTvlCapacity();
        uint256 userRemaining = _remainingUserCapacity(receiver);

        // min betwen both remaining capacities
        return tvlRemaining < userRemaining ? tvlRemaining : userRemaining;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        return convertToShares(maxAssets);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _remainingTvlCapacity() internal view returns (uint256) {
        uint256 cap = tvlCap;

        if (cap == 0) return type(uint256).max;

        uint256 assets = totalAssets();
        if (assets >= cap) return 0;
        return cap - assets;
    }

    function _remainingUserCapacity(address _user) internal view returns (uint256) {
        uint256 cap = perUserCap;

        if (cap == 0) return type(uint256).max;

        uint256 userAssets = convertToAssets(balanceOf(_user));
        if (userAssets >= cap) return 0;
        return cap - userAssets;
    }

    /// @notice Shares are not transferrable between users
    function _update(address from, address to, uint256 value) internal override {
        require(from == address(0) || to == address(0), SFVault__NonTransferableShares());
        super._update(from, to, value);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override {}
}
