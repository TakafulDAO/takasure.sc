// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {TSToken} from "contracts/token/TSToken.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";

contract TestDeployTakasure is Script {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function run()
        external
        returns (TSToken, address proxy, address contributionTokenAddress, HelperConfig)
    {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast();

        address implementation = address(new TakasurePool());
        proxy = UnsafeUpgrades.deployUUPSProxy(
            implementation,
            abi.encodeCall(
                TakasurePool.initialize,
                (
                    config.contributionToken,
                    config.feeClaimAddress,
                    config.daoMultisig,
                    config.takadaoOperator,
                    config.kycProvider,
                    config.pauseGuardian,
                    config.tokenAdmin,
                    config.tokenName,
                    config.tokenSymbol
                )
            )
        );

        TakasurePool takasurePool = TakasurePool(proxy);

        uint256 daoTokenAddressSlot = 1;
        bytes32 daoTokenAddressSlotBytes = vm.load(
            address(takasurePool),
            bytes32(uint256(daoTokenAddressSlot))
        );

        address daoTokenAddress = address(uint160(uint256(daoTokenAddressSlotBytes)));

        TSToken daoToken = TSToken(daoTokenAddress);

        vm.stopBroadcast();

        uint256 contributionTokenAddressSlot = 0;
        bytes32 contributionTokenAddressSlotBytes = vm.load(
            address(takasurePool),
            bytes32(uint256(contributionTokenAddressSlot))
        );

        contributionTokenAddress = address(uint160(uint256(contributionTokenAddressSlotBytes)));

        // contributionTokenAddress = takasurePool.getContributionTokenAddress();
        return (daoToken, proxy, contributionTokenAddress, helperConfig);
    }
}
