// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

interface IModuleManager {
    function addModule(address newModule) external;
    function isActiveModule(address module) external view returns (bool);
}
