// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {SFAndIFCircuitBreaker} from "contracts/breakers/SFAndIFCircuitBreaker.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";

contract DeploySFAndIFCircuitBreaker is Script {
    function run(IAddressManager addressManager) external returns (SFAndIFCircuitBreaker circuitBreaker) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast(msg.sender);

        // Deploy SFVault
        address circuitBreakerImplementation = address(new SFAndIFCircuitBreaker());

        address circuitBreakerAddress = UnsafeUpgrades.deployUUPSProxy(
            circuitBreakerImplementation, abi.encodeCall(SFAndIFCircuitBreaker.initialize, (addressManager))
        );

        circuitBreaker = SFAndIFCircuitBreaker(circuitBreakerAddress);

        vm.stopBroadcast();

        return (circuitBreaker);
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
