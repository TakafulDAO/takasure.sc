//SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

interface IKYCModule {
    function isKYCed(address member) external view returns (bool);
    function initialize(address _addressManager, string calldata _moduleName) external;
    function approveKYC(address memberWallet) external;
}
