// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

contract MockValuator {
    function quote(address, uint256 amount, address) external pure returns (uint256) {
        return amount;
    }

    function test() public view {}
}
