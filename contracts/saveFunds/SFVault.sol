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
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract SFVault is Initializable, UUPSUpgradeable, ERC4626Upgradeable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 _underlying) external initializer {
        __UUPSUpgradeable_init();
        __ERC4626_init(_underlying);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override {}
}
