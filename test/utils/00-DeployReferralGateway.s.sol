// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployReferralGateway is Script {
    function run() external returns (HelperConfig helperConfig, ReferralGateway referralGateway) {
        helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast(msg.sender);

        // Deploy ReferralGateway
        address referralGatewayImplementation = address(new ReferralGateway());

        address referralGatewayAddress = UnsafeUpgrades.deployUUPSProxy(
            referralGatewayImplementation,
            abi.encodeCall(
                ReferralGateway.initialize,
                (
                    config.takadaoOperator,
                    config.kycProvider,
                    config.pauseGuardian,
                    config.contributionToken
                )
            )
        );

        referralGateway = ReferralGateway(referralGatewayAddress);

        vm.stopBroadcast();

        return (helperConfig, referralGateway);
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
