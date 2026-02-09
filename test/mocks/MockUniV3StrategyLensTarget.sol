// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

contract MockUniV3StrategyLensTarget {
    address public asset;
    address public pool;
    address public otherToken;
    address public vault;
    bool public paused;
    uint256 public positionTokenId;
    int24 public tickLower;
    int24 public tickUpper;
    uint32 public twapWindow;
    uint256 private _totalAssets;

    constructor(address asset_, address other_, address pool_, address vault_) {
        asset = asset_;
        otherToken = other_;
        pool = pool_;
        vault = vault_;
    }

    function setPaused(bool v) external {
        paused = v;
    }

    function setPositionTokenId(uint256 v) external {
        positionTokenId = v;
    }

    function setTicks(int24 lower, int24 upper) external {
        tickLower = lower;
        tickUpper = upper;
    }

    function setTwapWindow(uint32 w) external {
        twapWindow = w;
    }

    function setTotalAssets(uint256 v) external {
        _totalAssets = v;
    }

    function totalAssets() external view returns (uint256) {
        return _totalAssets;
    }

    function test() public view {}
}
