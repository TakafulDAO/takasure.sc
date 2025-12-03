// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";

contract DeploySFVault is Script {
    function run(IAddressManager addressManager)
        external
        returns (HelperConfig.NetworkConfig memory config, SFVault sfVault)
    {
        HelperConfig helperConfig = new HelperConfig();
        config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast(msg.sender);

        // Deploy SFVault
        address sfVaultImplementation = address(new SFVault());

        address sfVaultAddress = UnsafeUpgrades.deployUUPSProxy(
            sfVaultImplementation,
            abi.encodeCall(SFVault.initialize, (addressManager, IERC20(config.contributionToken), "SF Vault", "SFV"))
        );

        sfVault = SFVault(sfVaultAddress);

        vm.stopBroadcast();

        return (config, sfVault);
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
