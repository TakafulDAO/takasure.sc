// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";

/// @dev Simple mock strategy to test `strategyAssets()` and `totalAssets()`.
contract MockSFStrategy is ISFStrategy {
    address public immutable override vault;
    address public immutable override asset;

    uint256 internal _totalAssets;
    uint256 internal _maxTVL;

    constructor(address _vault, address _asset) {
        vault = _vault;
        asset = _asset;
    }

    // --- view getters ---

    function totalAssets() external view override returns (uint256) {
        return _totalAssets;
    }

    function maxDeposit() external view override returns (uint256) {
        // for tests: unlimited unless maxTVL set
        if (_maxTVL == 0) return type(uint256).max;
        return _maxTVL - _totalAssets;
    }

    function maxWithdraw() external view override returns (uint256) {
        return _totalAssets;
    }

    // --- core hooks, dummy impls for compilation ---

    function deposit(uint256 assets, bytes calldata) external override returns (uint256 investedAssets) {
        // in tests we just simulate that all assets go into strategy
        _totalAssets += assets;
        return assets;
    }

    function withdraw(uint256 assets, address receiver, bytes calldata)
        external
        override
        returns (uint256 withdrawnAssets)
    {
        uint256 amount = assets > _totalAssets ? _totalAssets : assets;
        _totalAssets -= amount;

        if (receiver != address(0) && amount > 0) {
            // we don't actually need to transfer tokens in unit tests
            // (vault tests only care about the accounting via `totalAssets()`)
        }

        return amount;
    }

    // --- maintenance / admin (no-ops for tests) ---

    function pause() external override {}
    function unpause() external override {}
    function emergencyExit(address) external override {}

    function setMaxTVL(uint256 newMaxTVL) external override {
        _maxTVL = newMaxTVL;
    }
    function setConfig(bytes calldata) external override {}

    function test() public {}
}
