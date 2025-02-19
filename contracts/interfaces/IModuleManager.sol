// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

interface IModuleManager {
    function isActiveModule(address module) external view returns (bool);
}
