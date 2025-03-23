// SPDX-lICENSE// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployEntryModule is Script, GetContractAddress {
    function run() external returns (address entryModuleProxy) {
        uint256 chainId = block.chainid;

        address takasureReserve = _getContractAddress(chainId, "TakasureReserve");
        address prejoinModule = _getContractAddress(chainId, "ReferralGateway");
        address ccipReceiver = _getContractAddress(chainId, "TLDCcipReceiver");

        require(takasureReserve != address(0), "Deploy TakasureReserve first");
        require(prejoinModule != address(0), "Deploy ReferralGateway first");
        require(ccipReceiver != address(0), "Deploy TLDCcipReceiver first");

        address couponPool;
        if (chainId == ARB_MAINNET_CHAIN_ID)
            couponPool = 0x315BC6A41F98a748d903EC04b628205adC4C3cE5;
        else couponPool = 0xd26235AF7919C81470481fF4436B5465B0bbF6F2;

        vm.startBroadcast();
        entryModuleProxy = Upgrades.deployUUPSProxy(
            "EntryModule.sol",
            abi.encodeCall(
                EntryModule.initialize,
                (takasureReserve, prejoinModule, ccipReceiver, couponPool)
            )
        );

        vm.stopBroadcast();

        return (entryModuleProxy);
    }
}
