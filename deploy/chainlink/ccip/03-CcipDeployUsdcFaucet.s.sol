// SPDX-License-Identifier: GNU GPLv3

/// @notice Run only in Arbitrum (One and Sepolia)

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {UsdcFaucet} from "test/mocks/UsdcFaucet.sol";
import {CcipHelperConfig} from "deploy/utils/configs/CcipHelperConfig.s.sol";

contract DeployUsdcFaucet is Script {
    function run() external returns (UsdcFaucet) {
        CcipHelperConfig ccipHelperConfig = new CcipHelperConfig();

        CcipHelperConfig.CCIPNetworkConfig memory config = ccipHelperConfig.getConfigByChainId(
            block.chainid
        );

        vm.startBroadcast();

        // Deploy Usdc faucet contract
        UsdcFaucet faucet = new UsdcFaucet(config.router, config.link, config.usdc);

        vm.stopBroadcast();

        return (faucet);
    }
}
