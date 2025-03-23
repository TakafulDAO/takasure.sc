// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {UserRouter} from "contracts/router/UserRouter.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeUserRouter is Script, GetContractAddress {
    function run() external returns (address) {
        address userRouterAddress = _getContractAddress(block.chainid, "UserRouter");
        address oldImplementation = Upgrades.getImplementationAddress(userRouterAddress);
        console2.log("Old UserRouter implementation address: ", oldImplementation);

        vm.startBroadcast();

        Upgrades.upgradeProxy(userRouterAddress, "UserRouter.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(userRouterAddress);
        console2.log("New UserRouter implementation address: ", newImplementation);

        return (newImplementation);
    }
}
