// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract UpgradeReferralGateway is Script, GetContractAddress {
    function run() external returns (address) {
        address referralGatewayAddress = _getContractAddress(block.chainid, "ReferralGateway");
        address oldImplementation = Upgrades.getImplementationAddress(referralGatewayAddress);
        console2.log("Old Referral Gateway implementation address: ", oldImplementation);

        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast();

        // Upgrade ReferralGateway
        Upgrades.upgradeProxy(
            referralGatewayAddress,
            "ReferralGateway.sol",
            abi.encodeCall(ReferralGateway.initializeNewVersion, (config.takadaoOperator, 2)) // Todo: Change this address, just for testing purposes
        );

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(referralGatewayAddress);
        console2.log("New Referral Gateway implementation address: ", newImplementation);

        return (newImplementation);
    }
}
