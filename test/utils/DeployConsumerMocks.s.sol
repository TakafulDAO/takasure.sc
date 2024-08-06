// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {BenefitMultiplierConsumerMockError} from "test/mocks/BenefitMultiplierConsumerMockError.sol";
import {BenefitMultiplierConsumerMockFailed} from "test/mocks/BenefitMultiplierConsumerMockFailed.sol";
import {BenefitMultiplierConsumerMockSuccess} from "test/mocks/BenefitMultiplierConsumerMockSuccess.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";

contract DeployConsumerMocks is Script {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function run()
        external
        returns (
            BenefitMultiplierConsumerMockError,
            BenefitMultiplierConsumerMockFailed,
            BenefitMultiplierConsumerMockSuccess
        )
    {
        HelperConfig helperConfig = new HelperConfig();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast();

        BenefitMultiplierConsumerMockError bmConsumerError = new BenefitMultiplierConsumerMockError(
            config.functionsRouter,
            config.donId,
            config.gasLimit,
            config.subscriptionId
        );

        BenefitMultiplierConsumerMockFailed bmConsumerFailed = new BenefitMultiplierConsumerMockFailed(
                config.functionsRouter,
                config.donId,
                config.gasLimit,
                config.subscriptionId
            );

        BenefitMultiplierConsumerMockSuccess bmConsumerSuccess = new BenefitMultiplierConsumerMockSuccess(
                config.functionsRouter,
                config.donId,
                config.gasLimit,
                config.subscriptionId
            );

        vm.stopBroadcast();

        return (bmConsumerError, bmConsumerFailed, bmConsumerSuccess);
    }
}