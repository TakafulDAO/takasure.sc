// SPDX-lICENSE// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {RevenueModule} from "contracts/modules/RevenueModule.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployRevenueModule is Script, GetContractAddress {
    function run() external returns (address revenueModuleProxy) {
        address takasureReserve = _getContractAddress(block.chainid, "TakasureReserve");

        require(takasureReserve != address(0), "Deploy TakasureReserve first");

        vm.startBroadcast();
        revenueModuleProxy = Upgrades.deployUUPSProxy(
            "RevenueModule.sol",
            abi.encodeCall(RevenueModule.initialize, (takasureReserve))
        );

        vm.stopBroadcast();

        return (revenueModuleProxy);
    }
}
