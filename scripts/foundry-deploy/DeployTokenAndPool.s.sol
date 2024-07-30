// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {TSToken} from "../../contracts/token/TSToken.sol";
import {TakasurePool} from "../../contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumer} from "../../contracts/takasure/oracle/BenefitMultiplierConsumer.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployTokenAndPool is Script {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function run()
        external
        returns (
            TSToken,
            ERC1967Proxy,
            TakasurePool,
            BenefitMultiplierConsumer,
            address contributionTokenAddress,
            HelperConfig
        )
    {
        HelperConfig helperConfig = new HelperConfig();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();

        address deployerAddress = vm.addr(config.deployerKey);

        vm.startBroadcast(config.deployerKey);

        TSToken daoToken = new TSToken();
        TakasurePool takasurePool = new TakasurePool();
        ERC1967Proxy proxy = new ERC1967Proxy(address(takasurePool), "");

        BenefitMultiplierConsumer benefitMultiplierConsumer = new BenefitMultiplierConsumer(
            config.router,
            config.donId,
            config.gasLimit,
            config.subscriptionId,
            address(proxy)
        );

        TakasurePool(address(proxy)).initialize(
            config.contributionToken,
            address(daoToken),
            config.feeClaimAddress,
            config.daoOperator,
            address(benefitMultiplierConsumer)
        );

        daoToken.grantRole(MINTER_ROLE, address(proxy));
        daoToken.grantRole(BURNER_ROLE, address(proxy));

        bytes32 adminRole = daoToken.DEFAULT_ADMIN_ROLE();
        daoToken.grantRole(adminRole, config.daoOperator);

        daoToken.revokeRole(adminRole, deployerAddress);

        vm.stopBroadcast();

        contributionTokenAddress = TakasurePool(address(proxy)).getContributionTokenAddress();

        return (
            daoToken,
            proxy,
            takasurePool,
            benefitMultiplierConsumer,
            contributionTokenAddress,
            helperConfig
        );
    }
}
