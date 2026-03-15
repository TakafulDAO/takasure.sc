// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract DeployReferralGateway is Script, DeployConstants {
    using stdJson for string;

    function run() external returns (address proxy) {
        uint256 chainId = block.chainid;
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(chainId);

        vm.startBroadcast();

        // Deploy TakasurePool
        proxy = Upgrades.deployUUPSProxy(
            "ReferralGateway.sol",
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

        vm.stopBroadcast();

        return (proxy);
    }
}
