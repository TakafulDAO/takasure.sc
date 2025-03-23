// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeMemberModule is Script, GetContractAddress {
    function run() external returns (address) {
        address memberModuleAddress = _getContractAddress(block.chainid, "MemberModule");
        address oldImplementation = Upgrades.getImplementationAddress(memberModuleAddress);
        console2.log("Old MemberModule implementation address: ", oldImplementation);

        vm.startBroadcast();

        Upgrades.upgradeProxy(memberModuleAddress, "MemberModule.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(memberModuleAddress);
        console2.log("New MemberModule implementation address: ", newImplementation);

        return (newImplementation);
    }
}
