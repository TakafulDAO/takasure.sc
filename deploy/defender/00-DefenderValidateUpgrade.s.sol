// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {PrejoinModule} from "contracts/modules/PrejoinModule.sol";
import {Defender, Options, ApprovalProcessResponse} from "openzeppelin-foundry-upgrades/Defender.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DefenderValidateUpgrade is Script {
    function run() external {
        Options memory opts;

        Upgrades.validateUpgrade("PrejoinModule.sol", opts);

        console2.log("PrejoinModule.sol is upgradeable");
    }
}
