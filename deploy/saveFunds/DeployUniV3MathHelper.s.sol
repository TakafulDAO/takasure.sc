// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {UniswapV3MathHelper} from "contracts/helpers/uniswapHelpers/UniswapV3MathHelper.sol";

contract DeployUniV3MathHelper is Script {
    function run() external returns (address mathHelper) {
        vm.startBroadcast();

        mathHelper = address(new UniswapV3MathHelper());

        vm.stopBroadcast();

        return (mathHelper);
    }
}
