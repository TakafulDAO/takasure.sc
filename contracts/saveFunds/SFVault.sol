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

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/
    error NonTransferableShares();

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
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Shares are not transferrable between users
    function _update(address from, address to, uint256 value) internal override {
        require(from == address(0) || to == address(0), SFVault__NonTransferableShares());
        super._update(from, to, value);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override {}
}
