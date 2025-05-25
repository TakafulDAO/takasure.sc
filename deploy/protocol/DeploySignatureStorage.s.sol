// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SignatureStorage} from "contracts/helpers/SignatureStorage.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";

contract DeployTakasure is Script {
    function run() external returns (SignatureStorage signatureStorage) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast();

        signatureStorage = new SignatureStorage(config.kycProvider);

        vm.stopBroadcast();
    }
}
