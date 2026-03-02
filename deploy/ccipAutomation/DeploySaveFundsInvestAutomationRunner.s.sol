// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {SaveFundsInvestAutomationRunner} from
    "scripts/save-funds/automation/solidity/SaveFundsInvestAutomationRunner.sol";

contract DeploySaveFundsInvestAutomationRunner is Script, GetContractAddress {
    uint256 internal constant INTERVAL_SECONDS = 24 hours;
    uint256 internal constant MIN_IDLE_ASSETS = 0;

    function run() external returns (address proxy) {
        address vault = _getContractAddress(block.chainid, "SFVault");
        address aggregator = _getContractAddress(block.chainid, "SFStrategyAggregator");
        address uniV3Strategy = _getContractAddress(block.chainid, "SFUniswapV3Strategy");
        address addressManager = _getContractAddress(block.chainid, "AddressManager");

        vm.startBroadcast();

        proxy = Upgrades.deployUUPSProxy(
            "SaveFundsInvestAutomationRunner.sol",
            abi.encodeCall(
                SaveFundsInvestAutomationRunner.initialize,
                (vault, aggregator, uniV3Strategy, addressManager, INTERVAL_SECONDS, MIN_IDLE_ASSETS, msg.sender)
            )
        );

        vm.stopBroadcast();

        address implementation = Upgrades.getImplementationAddress(proxy);
        console2.log("SaveFundsInvestAutomationRunner proxy deployed at:");
        console2.logAddress(proxy);
        console2.log("SaveFundsInvestAutomationRunner implementation deployed at:");
        console2.logAddress(implementation);
        console2.log("intervalSeconds:", INTERVAL_SECONDS);
        console2.log("minIdleAssets:", MIN_IDLE_ASSETS);

        return proxy;
    }
}
