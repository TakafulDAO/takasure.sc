// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

contract MockERC721ApprovalForAll {
    mapping(address owner => mapping(address operator => bool)) public isApprovedForAll;

    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function test() public {}
}
