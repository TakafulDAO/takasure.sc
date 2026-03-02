// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";

interface IRevShareModule {
    function updateRevenue(address account) external;
}

contract RevShareModuleMock is IRevShareModule {
    address private _lastUpdated;

    function updateRevenue(address pioneer) external override {
        _lastUpdated = pioneer;
    }

    function lastUpdated() external view returns (address) {
        return _lastUpdated;
    }

    function test() external {}
}
