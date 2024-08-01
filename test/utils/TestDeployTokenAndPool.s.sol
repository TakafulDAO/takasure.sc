// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {TSToken} from "contracts/token/TSToken.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";

contract TestDeployTokenAndPool is Script {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function run()
        external
        returns (TSToken, address proxy, address contributionTokenAddress, HelperConfig)
    {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();
        address deployerAddress = vm.addr(config.deployerKey);

        vm.startBroadcast();

        TSToken daoToken = new TSToken();

        address implementation = address(new TakasurePool());
        proxy = UnsafeUpgrades.deployUUPSProxy(
            implementation,
            abi.encodeCall(
                TakasurePool.initialize,
                (
                    config.contributionToken,
                    address(daoToken),
                    config.feeClaimAddress,
                    config.daoOperator
                )
            )
        );

        TakasurePool takasurePool = TakasurePool(proxy);

        daoToken.grantRole(MINTER_ROLE, proxy);
        daoToken.grantRole(BURNER_ROLE, proxy);

        bytes32 adminRole = daoToken.DEFAULT_ADMIN_ROLE();
        daoToken.grantRole(adminRole, config.daoOperator);
        daoToken.revokeRole(adminRole, deployerAddress);

        vm.stopBroadcast();

        contributionTokenAddress = takasurePool.getContributionTokenAddress();
        return (daoToken, proxy, contributionTokenAddress, helperConfig);
    }
}
