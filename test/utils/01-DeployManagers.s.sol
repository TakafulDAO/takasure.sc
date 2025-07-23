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

        addressManager.addProtocolAddress(
            "MODULE_MANAGER",
            address(moduleManager),
            ProtocolAddressType.Protocol
        );

        addressManager.createNewRole(Roles.OPERATOR);
        addressManager.createNewRole(Roles.DAO_MULTISIG);
        addressManager.createNewRole(Roles.KYC_PROVIDER);

        addressManager.proposeRoleHolder(Roles.OPERATOR, config.takadaoOperator);
        addressManager.proposeRoleHolder(Roles.DAO_MULTISIG, config.daoMultisig);
        addressManager.proposeRoleHolder(Roles.KYC_PROVIDER, config.kycProvider);

        vm.stopBroadcast();

        vm.prank(config.takadaoOperator);
        addressManager.acceptProposedRole(Roles.OPERATOR);

        vm.prank(config.daoMultisig);
        addressManager.acceptProposedRole(Roles.DAO_MULTISIG);

        vm.prank(config.kycProvider);
        addressManager.acceptProposedRole(Roles.KYC_PROVIDER);

        return (config, addressManager, moduleManager);
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
