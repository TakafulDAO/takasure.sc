//SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

interface ITSToken {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amountToMint) external returns (bool);
}
