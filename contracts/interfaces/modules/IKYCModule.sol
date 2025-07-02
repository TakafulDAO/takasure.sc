// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

interface IKYCModule {
    function isKYCed(address user) external view returns (bool);
}
