// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";
import {SaveInvestCCIPReceiver} from "contracts/helpers/chainlink/SaveInvestCCIPReceiver.sol";

contract AllowlistCcipSenders is Script, DeployConstants, GetContractAddress {
    struct SourceConfig {
        uint256 chainId;
        uint64 chainSelector;
    }

    function run() external {
        uint256 receiverChainId = block.chainid;
        require(
            receiverChainId == ARB_MAINNET_CHAIN_ID || receiverChainId == ARB_SEPOLIA_CHAIN_ID,
            "Unsupported receiver chain"
        );

        address receiverAddress = _getContractAddress(receiverChainId, "SaveInvestCCIPReceiver");
        SaveInvestCCIPReceiver receiver = SaveInvestCCIPReceiver(receiverAddress);

        SourceConfig[] memory sources = _buildSources(receiverChainId);
        address[] memory senders = new address[](sources.length);

        for (uint256 i; i < sources.length; ++i) {
            senders[i] = _getContractAddress(sources[i].chainId, "SaveInvestCCIPSender");
        }

        vm.startBroadcast();

        for (uint256 i; i < sources.length; ++i) {
            uint64 sourceSelector = sources[i].chainSelector;
            address sender = senders[i];
            bool isAllowed = receiver.isSenderAllowedByChain(sourceSelector, sender);

            if (!isAllowed) {
                receiver.toggleAllowedSender(sourceSelector, sender);
                console2.log("Sender allowlisted");
            } else {
                console2.log("Sender already allowlisted");
            }

            console2.log("sourceChainSelector:", uint256(sourceSelector));
            console2.log("sender:", sender);
            console2.log("------------------------------------");
        }

        vm.stopBroadcast();
    }

    function _buildSources(uint256 receiverChainId) internal pure returns (SourceConfig[] memory sources_) {
        if (receiverChainId == ARB_MAINNET_CHAIN_ID) {
            sources_ = new SourceConfig[](5);
            sources_[0] = SourceConfig({chainId: AVAX_MAINNET_CHAIN_ID, chainSelector: AVAX_MAINNET_SELECTOR});
            sources_[1] = SourceConfig({chainId: BASE_MAINNET_CHAIN_ID, chainSelector: BASE_MAINNET_SELECTOR});
            sources_[2] = SourceConfig({chainId: ETH_MAINNET_CHAIN_ID, chainSelector: ETH_MAINNET_SELECTOR});
            sources_[3] = SourceConfig({chainId: OP_MAINNET_CHAIN_ID, chainSelector: OP_MAINNET_SELECTOR});
            sources_[4] = SourceConfig({chainId: POL_MAINNET_CHAIN_ID, chainSelector: POL_MAINNET_SELECTOR});
            return sources_;
        }

        sources_ = new SourceConfig[](3);
        sources_[0] = SourceConfig({chainId: BASE_SEPOLIA_CHAIN_ID, chainSelector: BASE_SEPOLIA_SELECTOR});
        sources_[1] = SourceConfig({chainId: ETH_SEPOLIA_CHAIN_ID, chainSelector: ETH_SEPOLIA_SELECTOR});
        sources_[2] = SourceConfig({chainId: OP_SEPOLIA_CHAIN_ID, chainSelector: OP_SEPOLIA_SELECTOR});
        return sources_;
    }
}
