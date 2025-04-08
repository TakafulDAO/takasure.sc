// SPDX-lICENSE// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {UserRouter} from "contracts/router/UserRouter.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployUserRouter is Script, GetContractAddress {
    function run() external returns (address userRouterProxy) {
        uint256 chainId = block.chainid;

        address takasureReserve = _getContractAddress(chainId, "TakasureReserve");
        address entryModule = _getContractAddress(chainId, "EntryModule");
        address memberModule = _getContractAddress(chainId, "MemberModule");

        require(takasureReserve != address(0), "Deploy TakasureReserve first");
        require(entryModule != address(0), "Deploy EntryModule first");
        require(memberModule != address(0), "Deploy MemberModule first");

        vm.startBroadcast();
        userRouterProxy = Upgrades.deployUUPSProxy(
            "UserRouter.sol",
            abi.encodeCall(UserRouter.initialize, (takasureReserve, entryModule, memberModule))
        );

        vm.stopBroadcast();

        return (userRouterProxy);
    }
}
