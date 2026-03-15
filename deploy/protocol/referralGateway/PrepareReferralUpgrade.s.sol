// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {Defender, Options, ApprovalProcessResponse} from "openzeppelin-foundry-upgrades/Defender.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract PrepareReferralUpgrade is Script {
    function run() external returns (address newImplementation) {
        Options memory opts;

        Upgrades.validateUpgrade("ReferralGateway.sol", opts);

        console2.log("ReferralGateway.sol is upgradeable");

        vm.startBroadcast();

        ReferralGateway referralGateway = new ReferralGateway();

        vm.stopBroadcast();

        return address(referralGateway);
    }
}
