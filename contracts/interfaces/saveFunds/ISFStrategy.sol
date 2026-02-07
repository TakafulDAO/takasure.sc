// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

interface ISFStrategy {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function maxWithdraw() external view returns (uint256);
    function deposit(uint256 assets, bytes calldata data) external returns (uint256 investedAssets);
    function withdraw(uint256 assets, address receiver, bytes calldata data) external returns (uint256 withdrawnAssets);
    function pause() external;
    function unpause() external;
    function emergencyExit(address receiver) external;
}

