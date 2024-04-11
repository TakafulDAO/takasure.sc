// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {MyContract} from "../../contracts/MyContract.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployMyContract is Script {
    function run() external returns (MyContract, HelperConfig) {
        HelperConfig config = new HelperConfig();

        uint256 deployerKey = config.activeNetworkConfig();

        vm.startBroadcast(deployerKey);

        MyContract myContract = new MyContract();

        vm.stopBroadcast();

        return (myContract, config);
    }
}
