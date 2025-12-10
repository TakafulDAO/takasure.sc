// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployRevShareModule is Script {
    function run() external returns (address revShareModule) {
        address addressManagerAddress = _getContractAddress(block.chainid, "AddressManager");

        vm.startBroadcast();
        revShareModule = Upgrades.deployUUPSProxy(
            "RevShareModule.sol",
            abi.encodeCall(RevShareModule.initialize, (addressManagerAddress, "REVENUE_SHARE_MODULE"))
        );

        vm.stopBroadcast();

        console2.log("RevShareModule deployed at: ", revShareModule);

        return (revShareModule);
    }
}
