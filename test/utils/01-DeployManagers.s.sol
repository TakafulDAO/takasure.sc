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
    address beacon;
    address addressManagerImplementation;
    address addressManagerProxy;
    address moduleManagerImplementation;
    address moduleManagerProxy;

    function run()
        external
        returns (
            HelperConfig.NetworkConfig memory config,
            AddressManager addressManager,
            ModuleManager moduleManager,
            address operator,
            address daoMultisig,
            address kycProvider,
            address couponRedeemer,
            address feeClaimAddress
        )
    {
        HelperConfig helperConfig = new HelperConfig();
        config = helperConfig.getConfigByChainId(block.chainid);

        couponRedeemer = makeAddr("couponRedeemer");

        vm.startBroadcast(msg.sender);

        beacon = UnsafeUpgrades.deployBeacon(address(new BenefitModule()), msg.sender);

        addressManagerImplementation = address(new AddressManager());
        addressManagerProxy = UnsafeUpgrades.deployUUPSProxy(
            addressManagerImplementation,
            abi.encodeCall(AddressManager.initialize, (msg.sender, beacon))
        );
        addressManager = AddressManager(addressManagerProxy);

        moduleManagerImplementation = address(new ModuleManager());
        moduleManagerProxy = UnsafeUpgrades.deployUUPSProxy(
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
        addressManager.createNewRole(Roles.COUPON_REDEEMER);

        addressManager.proposeRoleHolder(Roles.OPERATOR, config.takadaoOperator);
        addressManager.proposeRoleHolder(Roles.DAO_MULTISIG, config.daoMultisig);
        addressManager.proposeRoleHolder(Roles.KYC_PROVIDER, config.kycProvider);
        addressManager.proposeRoleHolder(Roles.COUPON_REDEEMER, couponRedeemer);

        addressManager.addProtocolAddress(
            "CONTRIBUTION_TOKEN",
            config.contributionToken,
            ProtocolAddressType.Protocol
        );

        addressManager.addProtocolAddress(
            "FEE_CLAIM_ADDRESS",
            config.feeClaimAddress,
            ProtocolAddressType.Admin
        );
        vm.stopBroadcast();

        vm.prank(config.takadaoOperator);
        addressManager.acceptProposedRole(Roles.OPERATOR);

        vm.prank(config.daoMultisig);
        addressManager.acceptProposedRole(Roles.DAO_MULTISIG);

        vm.prank(config.kycProvider);
        addressManager.acceptProposedRole(Roles.KYC_PROVIDER);

        vm.prank(couponRedeemer);
        addressManager.acceptProposedRole(Roles.COUPON_REDEEMER);

        return (
            config,
            addressManager,
            moduleManager,
            config.takadaoOperator,
            config.daoMultisig,
            config.kycProvider,
            couponRedeemer,
            config.feeClaimAddress
        );
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
