//SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

interface ITSToken {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amountToMint) external returns (bool);
    function burnFrom(address account, uint256 value) external;
}
