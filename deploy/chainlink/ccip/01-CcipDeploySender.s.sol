// SPDX-License-Identifier: GNU GPLv3

/// @notice Run in Avax (Mainnet and Fuji), Base (Mainnet and Sepolia), Ethereum (Mainnet and Sepolia),
///         Optimism (Mainnet and Sepolia), Polygon (Mainnet and Amoy)

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {Sender} from "contracts/chainlink/ccip/Sender.sol";
import {CcipHelperConfig} from "deploy/utils/configs/CcipHelperConfig.s.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract DeploySender is Script, DeployConstants, GetContractAddress {
    function run() external returns (Sender) {
        uint256 chainId = block.chainid;

        CcipHelperConfig ccipHelperConfig = new CcipHelperConfig();

        CcipHelperConfig.CCIPNetworkConfig memory config = ccipHelperConfig.getConfigByChainId(
            chainId
        );

        address receiverContractAddress;
        uint64 destinationChainSelector;
        bytes32 salt = "2020";

        if (
            chainId == AVAX_FUJI_CHAIN_ID ||
            chainId == BASE_SEPOLIA_CHAIN_ID ||
            chainId == ETH_SEPOLIA_CHAIN_ID ||
            chainId == OP_SEPOLIA_CHAIN_ID ||
            chainId == POL_AMOY_CHAIN_ID
        ) {
            receiverContractAddress = _getContractAddress(ARB_SEPOLIA_CHAIN_ID, "Receiver");
            destinationChainSelector = ARB_SEPOLIA_SELECTOR;
        } else {
            receiverContractAddress = _getContractAddress(ARB_MAINNET_CHAIN_ID, "Receiver");
            destinationChainSelector = ARB_MAINNET_SELECTOR;
        }

        vm.startBroadcast();

        // Deploy Sender contract
        Sender sender = new Sender{salt: salt}(
            config.router,
            config.link,
            config.usdc,
            receiverContractAddress,
            destinationChainSelector
        );

        vm.stopBroadcast();

        return (sender);
    }
}
