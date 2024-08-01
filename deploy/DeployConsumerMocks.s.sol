// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {BenefitMultiplierConsumerMockError} from "test/mocks/BenefitMultiplierConsumerMockError.sol";
import {BenefitMultiplierConsumerMockFailed} from "test/mocks/BenefitMultiplierConsumerMockFailed.sol";
import {BenefitMultiplierConsumerMockSuccess} from "test/mocks/BenefitMultiplierConsumerMockSuccess.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployConsumerMocks is Script {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function run()
        external
        returns (
            BenefitMultiplierConsumerMockError,
            BenefitMultiplierConsumerMockFailed,
            BenefitMultiplierConsumerMockSuccess,
            address
        )
    {
        HelperConfig helperConfig = new HelperConfig();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();

        address deployerAddress = vm.addr(config.deployerKey);

        vm.startBroadcast(config.deployerKey);

        BenefitMultiplierConsumerMockError bmConsumerError = new BenefitMultiplierConsumerMockError(
            config.router,
            config.donId,
            config.gasLimit,
            config.subscriptionId,
            address(0)
        );

        BenefitMultiplierConsumerMockFailed bmConsumerFailed = new BenefitMultiplierConsumerMockFailed(
                config.router,
                config.donId,
                config.gasLimit,
                config.subscriptionId,
                address(0)
            );

        BenefitMultiplierConsumerMockSuccess bmConsumerSuccess = new BenefitMultiplierConsumerMockSuccess(
                config.router,
                config.donId,
                config.gasLimit,
                config.subscriptionId,
                address(0)
            );

        vm.stopBroadcast();

        return (bmConsumerError, bmConsumerFailed, bmConsumerSuccess, deployerAddress);
    }
}
