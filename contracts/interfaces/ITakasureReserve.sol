//SPDX-License-Identifier: GPL-3.0

import {NewReserve, Member} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.25;

interface ITakasureReserve {
    function bmConsumer() external view returns (address);
    function kycProvider() external view returns (address);
    function feeClaimAddress() external view returns (address);
    function takadaoOperator() external view returns (address);

    function setMemberValuesFromModule(Member memory newMember) external;
    function setReserveValuesFromModule(NewReserve memory newReserve) external;

    function getMemberFromAddress(address member) external view returns (Member memory);
    function getMemberFromId(uint256 memberId) external view returns (address);

    function getReserveValues() external view returns (NewReserve memory);
}
