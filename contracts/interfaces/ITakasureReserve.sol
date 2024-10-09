//SPDX-License-Identifier: GPL-3.0

import {Reserve, Member, CashFlowVars} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.27;

interface ITakasureReserve {
    function bmConsumer() external view returns (address);
    function kycProvider() external view returns (address);
    function feeClaimAddress() external view returns (address);
    function takadaoOperator() external view returns (address);
    function daoMultisig() external view returns (address);
    function monthToCashFlow(uint16 month) external view returns (uint256 monthCashFlow);
    function dayToCashFlow(uint16 month, uint8 day) external view returns (uint256 dayCashFlow);

    function setMemberValuesFromModule(Member memory newMember) external;
    function setReserveValuesFromModule(Reserve memory reserve) external;
    function setCashFlowValuesFromModule(CashFlowVars memory newCashFlowVars) external;
    function setMonthToCashFlowValuesFromModule(uint16 month, uint256 monthCashFlow) external;
    function setDayToCashFlowValuesFromModule(
        uint16 month,
        uint8 day,
        uint256 dayCashFlow
    ) external;

    function getMemberFromAddress(address member) external view returns (Member memory);
    function getMemberFromId(uint256 memberId) external view returns (address);
    function getReserveValues() external view returns (Reserve memory);
    function getCashFlowValues() external view returns (CashFlowVars memory);
}
