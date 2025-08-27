//SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

interface IRevShareNFT {
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
}
