// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFUniswapV3Strategy
 * @author Maikel Ordaz
 * @notice Uniswap V3 strategy implementation for SaveFunds vaults.
 */

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

pragma solidity 0.8.28;

contract SFUniswapV3Strategy is Initializable, UUPSUpgradeable {
    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() external {
        __UUPSUpgradeable_init();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    ///@dev required by the OZ UUPS module.
    function _authorizeUpgrade(address newImplementation) internal override {}
}
