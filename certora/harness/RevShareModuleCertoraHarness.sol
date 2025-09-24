// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

/**
 * @title RevShareModuleCertoraHarness
 * @notice Thin wrapper around RevShareModule to expose internal helpers for formal specs.
 *         No logic changes; only convenience accessors and an explicit init entrypoint.
 */
contract RevShareModuleCertoraHarness is RevShareModule {
    /// @notice Call the module initializer (same as production initialize)
    /// @dev Parent initialize is `external` so we must use an external self-call.
    function h_init(address addressManager_) external {
        this.initialize(addressManager_);
    }

    /*//////////////////////////////////////////////////////////////
                              READ HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Expose internal last-time-applicable
    function h_lastTimeApplicable() external view returns (uint256) {
        return _lastTimeApplicable();
    }

    /// @notice Expose the current revenue receiver resolved via AddressManager
    function h_getRevenueReceiver() external view returns (address) {
        return _getRevenueReceiver();
    }

    /// @notice Check if an arbitrary address would be considered a REVENUE_CLAIMER
    function h_isClaimer(address who) external view returns (bool) {
        return addressManager.hasRole(Roles.REVENUE_CLAIMER, who);
    }

    /// @notice Return the internal constants (for specs to avoid magic numbers)
    function h_pioneersSharePct() external pure returns (uint256) {
        return 75;
    }
    function h_takadaoSharePct() external pure returns (uint256) {
        return 25;
    }
    function h_precision() external pure returns (uint256) {
        return 1e18;
    }

    /// @notice Expose the AddressManager used by the module
    function h_addressManager() external view returns (address) {
        return address(addressManager);
    }

    /*//////////////////////////////////////////////////////////////
                             STATE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Force a global accumulator checkpoint
    function h_updateGlobal() external {
        _updateGlobal();
    }

    /*//////////////////////////////////////////////////////////////
                               ADDRESSES
    //////////////////////////////////////////////////////////////*/

    function revenueReceiver() external view returns (address) {
        return _getRevenueReceiver();
    }
}
