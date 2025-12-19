// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestAggSubStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlying;
    uint256 public harvestCount;
    uint256 public rebalanceCount;

    bool public returnZeroOnWithdraw;
    bool public forceMaxWithdraw;
    uint256 public forcedMaxWithdraw;

    constructor(IERC20 _underlying) {
        underlying = _underlying;
    }

    function setReturnZeroOnWithdraw(bool v) external {
        returnZeroOnWithdraw = v;
    }

    function setForcedMaxWithdraw(uint256 v) external {
        forceMaxWithdraw = true;
        forcedMaxWithdraw = v;
    }

    // ISFStrategy-like
    function deposit(uint256 assets, bytes calldata) external returns (uint256 invested) {
        if (assets == 0) return 0;
        underlying.safeTransferFrom(msg.sender, address(this), assets);
        return assets;
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function withdraw(uint256 assets, address receiver, bytes calldata) external returns (uint256 withdrawn) {
        if (assets == 0 || receiver == address(0) || returnZeroOnWithdraw) return 0;

        uint256 bal = underlying.balanceOf(address(this));
        uint256 toSend = assets > bal ? bal : assets;
        if (toSend == 0) return 0;

        underlying.safeTransfer(receiver, toSend);
        return toSend;
    }

    function totalAssets() external view returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    function maxWithdraw() external view returns (uint256) {
        if (forceMaxWithdraw) return forcedMaxWithdraw;
        return underlying.balanceOf(address(this));
    }

    // maintenance-like
    function harvest(bytes calldata) external {
        harvestCount++;
    }

    function rebalance(bytes calldata) external {
        rebalanceCount++;
    }

    function test() external {}
}
