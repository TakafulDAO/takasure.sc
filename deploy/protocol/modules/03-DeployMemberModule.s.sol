// SPDX-lICENSE// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployMemberModule is Script, GetContractAddress {
    function run() external returns (address memberModuleProxy) {
        address takasureReserve = _getContractAddress(block.chainid, "TakasureReserve");

        require(takasureReserve != address(0), "Deploy TakasureReserve first");

        vm.startBroadcast();
        memberModuleProxy = Upgrades.deployUUPSProxy(
            "MemberModule.sol",
            abi.encodeCall(MemberModule.initialize, (takasureReserve))
        );

        vm.stopBroadcast();

        return (memberModuleProxy);
    }
}
