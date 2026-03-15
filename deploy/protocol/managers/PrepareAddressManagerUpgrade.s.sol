// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {Defender, Options, ApprovalProcessResponse} from "openzeppelin-foundry-upgrades/Defender.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract PrepareAddressManagerUpgrade is Script {
    function run() external returns (address newImplementation) {
        Options memory opts;

        Upgrades.validateUpgrade("AddressManager.sol", opts);

        console2.log("AddressManager.sol is upgradeable");

        vm.startBroadcast();

        AddressManager addressManager = new AddressManager();

        vm.stopBroadcast();

        return address(addressManager);
    }
}
