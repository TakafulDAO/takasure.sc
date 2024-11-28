// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";

contract UpgradeReferralGateway is Script, GetContractAddress {
    function run() external returns (address) {
        address referralGatewayAddress = _getContractAddress(block.chainid, "ReferralGateway");
        address oldImplementation = Upgrades.getImplementationAddress(referralGatewayAddress);
        console2.log("Old Referral Gateway implementation address: ", oldImplementation);

        vm.startBroadcast();

        // Upgrade ReferralGateway
        Upgrades.upgradeProxy(referralGatewayAddress, "ReferralGateway.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(referralGatewayAddress);
        console2.log("New Referral Gateway implementation address: ", newImplementation);

        return (newImplementation);
    }
}
