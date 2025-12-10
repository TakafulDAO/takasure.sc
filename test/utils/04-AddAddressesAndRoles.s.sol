// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ProtocolAddressType} from "contracts/types/TakasureTypes.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract AddAddressesAndRoles is Script {
    function run(AddressManager addressManager, HelperConfig.NetworkConfig memory config, address moduleManager)
        external
        returns (
            address operator,
            address daoMultisig,
            address kycProvider,
            address couponRedeemer,
            address feeClaimAddress,
            address couponPool,
            address revenueReceiver
        )
    {
        couponRedeemer = makeAddr("couponRedeemer");
        couponPool = makeAddr("couponPool");
        revenueReceiver = makeAddr("revenueReceiver");

        vm.startPrank(addressManager.owner());
        addressManager.createNewRole(Roles.OPERATOR);
        addressManager.createNewRole(Roles.DAO_MULTISIG);
        addressManager.createNewRole(Roles.KYC_PROVIDER);
        addressManager.createNewRole(Roles.BACKEND_ADMIN);
        addressManager.createNewRole(Roles.REVENUE_CLAIMER);

        addressManager.proposeRoleHolder(Roles.OPERATOR, config.takadaoOperator);
        addressManager.proposeRoleHolder(Roles.DAO_MULTISIG, config.daoMultisig);
        addressManager.proposeRoleHolder(Roles.KYC_PROVIDER, config.kycProvider);
        addressManager.proposeRoleHolder(Roles.BACKEND_ADMIN, couponRedeemer);
        addressManager.proposeRoleHolder(Roles.REVENUE_CLAIMER, config.takadaoOperator);

        addressManager.addProtocolAddress(
            "PROTOCOL__MODULE_MANAGER", address(moduleManager), ProtocolAddressType.Protocol
        );

        addressManager.addProtocolAddress(
            "PROTOCOL__CONTRIBUTION_TOKEN", config.contributionToken, ProtocolAddressType.Protocol
        );

        addressManager.addProtocolAddress("ADMIN__FEE_CLAIM_ADDRESS", config.feeClaimAddress, ProtocolAddressType.Admin);

        addressManager.addProtocolAddress("PROTOCOL__COUPON_POOL", couponPool, ProtocolAddressType.Protocol);

        addressManager.addProtocolAddress("ADMIN__REVENUE_RECEIVER", revenueReceiver, ProtocolAddressType.Admin);
        vm.stopPrank();

        vm.startPrank(config.takadaoOperator);
        addressManager.acceptProposedRole(Roles.OPERATOR);
        addressManager.acceptProposedRole(Roles.REVENUE_CLAIMER);
        vm.stopPrank();

        vm.prank(config.daoMultisig);
        addressManager.acceptProposedRole(Roles.DAO_MULTISIG);

        vm.prank(config.kycProvider);
        addressManager.acceptProposedRole(Roles.KYC_PROVIDER);

        vm.prank(couponRedeemer);
        addressManager.acceptProposedRole(Roles.BACKEND_ADMIN);

        return (
            config.takadaoOperator,
            config.daoMultisig,
            config.kycProvider,
            couponRedeemer,
            config.feeClaimAddress,
            couponPool,
            revenueReceiver
        );
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
