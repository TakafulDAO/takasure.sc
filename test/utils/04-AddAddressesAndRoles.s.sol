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

contract AddAddressesAndRoles is Script {
    function run(
        AddressManager addressManager,
        HelperConfig.NetworkConfig memory config,
        address moduleManager
    )
        external
        returns (
            address operator,
            address daoMultisig,
            address kycProvider,
            address couponRedeemer,
            address feeClaimAddress,
            address couponPool
        )
    {
        couponRedeemer = makeAddr("couponRedeemer");
        couponPool = makeAddr("couponPool");

        vm.startPrank(addressManager.owner());
        addressManager.createNewRole(Roles.OPERATOR);
        addressManager.createNewRole(Roles.DAO_MULTISIG);
        addressManager.createNewRole(Roles.KYC_PROVIDER);
        addressManager.createNewRole(Roles.COUPON_REDEEMER);

        addressManager.proposeRoleHolder(Roles.OPERATOR, config.takadaoOperator);
        addressManager.proposeRoleHolder(Roles.DAO_MULTISIG, config.daoMultisig);
        addressManager.proposeRoleHolder(Roles.KYC_PROVIDER, config.kycProvider);
        addressManager.proposeRoleHolder(Roles.COUPON_REDEEMER, couponRedeemer);

        addressManager.addProtocolAddress(
            "MODULE_MANAGER",
            address(moduleManager),
            ProtocolAddressType.Protocol
        );

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

        addressManager.addProtocolAddress("COUPON_POOL", couponPool, ProtocolAddressType.Protocol);
        vm.stopPrank();

        vm.prank(config.takadaoOperator);
        addressManager.acceptProposedRole(Roles.OPERATOR);

        vm.prank(config.daoMultisig);
        addressManager.acceptProposedRole(Roles.DAO_MULTISIG);

        vm.prank(config.kycProvider);
        addressManager.acceptProposedRole(Roles.KYC_PROVIDER);

        vm.prank(couponRedeemer);
        addressManager.acceptProposedRole(Roles.COUPON_REDEEMER);

        return (
            config.takadaoOperator,
            config.daoMultisig,
            config.kycProvider,
            couponRedeemer,
            config.feeClaimAddress,
            couponPool
        );
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
