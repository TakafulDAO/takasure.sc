// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

interface ISFTwapValuator {
    function quote(address token, uint256 amount, address underlying) external view returns (uint256);
}
