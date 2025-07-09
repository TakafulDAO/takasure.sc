//SPDX-License-Identifier: GPL-3.0

/**
 * @title ReserveAndMemberValuesHook
 * @author Maikel Ordaz
 * @notice This contract will help the modules to set new values in the reserve contract
 * @dev This functions are intended to be called before and after certain actions in the Core contracts
 * @dev The logic in this contract will have one main purpose, and for that it will follow the next steps:
 *      1. Get the current values of the reserve and/or a given member from the Core contracts
 *      2. Set new values for the reserve and/or a given member in the Core contracts
 */

import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ISubscriptionModule} from "contracts/interfaces/modules/ISubscriptionModule.sol";

import {AssociationMember} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;

abstract contract AssociationHooks {
    function _getAssociationMembersValuesHook(
        IAddressManager _addressManager,
        address _memberWallet
    ) internal view returns (AssociationMember memory member_) {
        address subscriptionModuleAddress = _addressManager
            .getProtocolAddressByName("SUBSCRIPTION_MODULE")
            .addr;
        ISubscriptionModule subscriptionModule = ISubscriptionModule(subscriptionModuleAddress);

        member_ = subscriptionModule.getMember(_memberWallet);
    }

    function _setAssociationMembersValuesHook(
        IAddressManager _addressManager,
        AssociationMember memory _newMember
    ) internal {
        address subscriptionModuleAddress = _addressManager
            .getProtocolAddressByName("SUBSCRIPTION_MODULE")
            .addr;
        ISubscriptionModule subscriptionModule = ISubscriptionModule(subscriptionModuleAddress);

        subscriptionModule.modifyAssociationMember(_newMember);
    }
}
