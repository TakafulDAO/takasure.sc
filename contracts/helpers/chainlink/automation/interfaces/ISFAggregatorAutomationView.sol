// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

interface ISFAggregatorAutomationView {
    struct SubStrategyInfo {
        address strategy;
        uint16 targetWeightBPS;
        bool isActive;
    }

    function getSubStrategies() external view returns (SubStrategyInfo[] memory);
}
