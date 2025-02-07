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

import {Reserve, Member} from "contracts/types/TakasureTypes.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";

pragma solidity 0.8.28;

abstract contract ReserveAndMemberValuesHook {
    function _getReservesValuesHook(
        ITakasureReserve _takasureReserve
    ) internal view returns (Reserve memory reserve_) {
        reserve_ = _takasureReserve.getReserveValues();
    }

    function _getMembersValuesHook(
        ITakasureReserve _takasureReserve,
        address _memberWallet
    ) internal view returns (Member memory member_) {
        member_ = _takasureReserve.getMemberFromAddress(_memberWallet);
    }

    function _getReserveAndMemberValuesHook(
        ITakasureReserve _takasureReserve,
        address _memberWallet
    ) internal view returns (Reserve memory reserve_, Member memory member_) {
        reserve_ = _takasureReserve.getReserveValues();
        member_ = _takasureReserve.getMemberFromAddress(_memberWallet);
    }

    function _setReservesValuesHook(
        ITakasureReserve _takasureReserve,
        Reserve memory _reserve
    ) internal {
        _takasureReserve.setReserveValuesFromModule(_reserve);
    }

    function _setMembersValuesHook(
        ITakasureReserve _takasureReserve,
        Member memory _newMember
    ) internal {
        _takasureReserve.setMemberValuesFromModule(_newMember);
    }

    function _setNewReserveAndMemberValuesHook(
        ITakasureReserve _takasureReserve,
        Reserve memory _reserve,
        Member memory _newMember
    ) internal {
        _takasureReserve.setReserveValuesFromModule(_reserve);
        _takasureReserve.setMemberValuesFromModule(_newMember);
    }
}
