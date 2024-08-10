// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";

contract DeployConsumerMocks is Script {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function run() external returns (BenefitMultiplierConsumerMock) {
        HelperConfig helperConfig = new HelperConfig();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast();

        BenefitMultiplierConsumerMock bmConnsumerMock = new BenefitMultiplierConsumerMock(
            config.functionsRouter,
            config.donId,
            config.gasLimit,
            config.subscriptionId
        );

        vm.stopBroadcast();

        return (bmConnsumerMock);
    }
}
