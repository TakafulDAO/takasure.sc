//SPDX-License-Identifier: GPL-3.0

/**
 * @title ReserveAndMemberValues
 * @author Maikel Ordaz
 * @notice It help the modules to set new values in the reserve contract
 */

import {Reserve, Member} from "contracts/types/TakasureTypes.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";

pragma solidity 0.8.28;

library ReserveAndMemberValues {
    function _getReserveAndMemberValuesHook(
        ITakasureReserve _takasureReserve,
        address _memberWallet
    ) internal view returns (Reserve memory reserve_, Member memory member_) {
        reserve_ = _takasureReserve.getReserveValues();
        member_ = _takasureReserve.getMemberFromAddress(_memberWallet);
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
