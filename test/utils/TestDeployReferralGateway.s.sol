// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";

contract TestDeployReferralGateway is Script {
    function run()
        external
        returns (ReferralGateway, address proxy, address, address, HelperConfig)
    {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast();

        address implementation = address(new ReferralGateway());
        proxy = UnsafeUpgrades.deployUUPSProxy(
            implementation,
            abi.encodeCall(
                ReferralGateway.initialize,
                (config.takadaoOperator, config.kycProvider, config.contributionToken)
            )
        );

        ReferralGateway referralGateway = ReferralGateway(proxy);

        vm.stopBroadcast();

        return (referralGateway, proxy, config.contributionToken, config.kycProvider, helperConfig);
    }
}