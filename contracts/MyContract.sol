// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.24;

contract MyContract {
    uint256 public myNumber;

    function setNumber(uint256 _number) public {
        myNumber = _number;
    }
}
