// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFUniswapV3Strategy
 * @author Maikel Ordaz
 * @notice Uniswap V3 strategy implementation for SaveFunds vaults.
 */
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

pragma solidity 0.8.28;

contract SFUniswapV3Strategy is Initializable, UUPSUpgradeable {
    IAddressManager public addressManager;

    /*//////////////////////////////////////////////////////////////
                           EVENTS AND ERRORS
    //////////////////////////////////////////////////////////////*/

    error SFUniswapV3Strategy__NotAuthorizedCaller();
    error SFUniswapV3Strategy__NotAddressZero();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyRole(bytes32 role, address addressManagerAddress) {
        require(
            IAddressManager(addressManagerAddress).hasRole(role, msg.sender), SFUniswapV3Strategy__NotAuthorizedCaller()
        );
        _;
    }

    modifier notAddressZero(address addr) {
        require(addr != address(0), SFUniswapV3Strategy__NotAddressZero());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IAddressManager _addressManager) external initializer notAddressZero(address(_addressManager)) {
        __UUPSUpgradeable_init();

        addressManager = _addressManager;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev required by the OZ UUPS module.
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(Roles.OPERATOR, address(addressManager))
    {}
}
