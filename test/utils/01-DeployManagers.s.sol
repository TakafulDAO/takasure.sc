// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {BenefitModule} from "contracts/modules/BenefitModule.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ProtocolAddressType} from "contracts/types/TakasureTypes.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract DeployManagers is Script {
    function run()
        external
        returns (
            HelperConfig.NetworkConfig memory config,
            AddressManager addressManager,
            ModuleManager moduleManager
        )
    {
        HelperConfig helperConfig = new HelperConfig();
        config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast(msg.sender);

        address beacon = UnsafeUpgrades.deployBeacon(address(new BenefitModule()), msg.sender);

        address addressManagerImplementation = address(new AddressManager());
        address addressManagerProxy = UnsafeUpgrades.deployUUPSProxy(
            addressManagerImplementation,
            abi.encodeCall(AddressManager.initialize, (msg.sender, beacon))
        );
        addressManager = AddressManager(addressManagerProxy);

        address moduleManagerImplementation = address(new ModuleManager());
        address moduleManagerProxy = UnsafeUpgrades.deployUUPSProxy(
            moduleManagerImplementation,
            abi.encodeCall(ModuleManager.initialize, (addressManagerProxy))
        );
        moduleManager = ModuleManager(moduleManagerProxy);

        vm.stopBroadcast();

        return (config, addressManager, moduleManager);
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
