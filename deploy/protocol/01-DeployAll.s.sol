// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";
import {RevenueModule} from "contracts/modules/RevenueModule.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployTakasureReserve is Script {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant MINTER_ADMIN_ROLE = keccak256("MINTER_ADMIN_ROLE");
    bytes32 public constant BURNER_ADMIN_ROLE = keccak256("BURNER_ADMIN_ROLE");

    function run()
        external
        returns (
            address takasureReserve,
            address entryModule,
            address memberModule,
            address revenueModule
        )
    {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast();

        // Deploy TakasureReserve
        takasureReserve = Upgrades.deployUUPSProxy(
            "TakasureReserve.sol",
            abi.encodeCall(
                TakasureReserve.initialize,
                (
                    config.contributionToken,
                    config.feeClaimAddress,
                    config.daoMultisig,
                    config.takadaoOperator,
                    config.kycProvider,
                    config.pauseGuardian
                )
            )
        );

        // Deploy EntryModule
        entryModule = Upgrades.deployUUPSProxy(
            "EntryModule.sol",
            abi.encodeCall(EntryModule.initialize, (takasureReserve))
        );

        // Deploy MemberModule
        memberModule = Upgrades.deployUUPSProxy(
            "MemberModule.sol",
            abi.encodeCall(MemberModule.initialize, (takasureReserve))
        );

        // Deploy RevemueModule
        revenueModule = Upgrades.deployUUPSProxy(
            "RevenueModule.sol",
            abi.encodeCall(RevenueModule.initialize, (takasureReserve))
        );

        // Set EntryModule as a module in TakasurePool
        // TakasureReserve(takasureReserve).setNewModuleContract(entryModule);

        // Set MemberModule as a module in TakasurePool
        // TakasureReserve(takasureReserve).setNewModuleContract(memberModule);

        // Set RevenueModule as a module in TakasurePool
        // TakasureReserve(takasureReserve).setNewModuleContract(revenueModule);

        // After this set the dao multisig as the DEFAULT_ADMIN_ROLE in TakasureReserve
        TakasureReserve(takasureReserve).grantRole(0x00, config.daoMultisig);

        // And renounce the DEFAULT_ADMIN_ROLE in TakasureReserve
        TakasureReserve(takasureReserve).renounceRole(0x00, msg.sender);

        vm.stopBroadcast();
    }
}
