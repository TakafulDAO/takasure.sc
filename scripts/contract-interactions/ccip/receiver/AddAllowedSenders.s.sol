// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {TLDCcipReceiver} from "contracts/helpers/chainlink/ccip/TLDCcipReceiver.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract AddAllowedSenders is Script, DeployConstants, GetContractAddress {
    function run() public {
        uint256 chainId = block.chainid;

        address receiverAddress = _getContractAddress(chainId, "TLDCcipReceiver");

        TLDCcipReceiver receiver = TLDCcipReceiver(receiverAddress);

        vm.startBroadcast();

        if (chainId == ARB_SEPOLIA_CHAIN_ID) {
            receiver.toggleAllowedSender({
                chainSelector: AVAX_FUJI_SELECTOR,
                sender: _getContractAddress(AVAX_FUJI_CHAIN_ID, "TLDCcipSender")
            });
            receiver.toggleAllowedSender({
                chainSelector: BASE_SEPOLIA_SELECTOR,
                sender: _getContractAddress(BASE_SEPOLIA_CHAIN_ID, "TLDCcipSender")
            });
            receiver.toggleAllowedSender({
                chainSelector: ETH_SEPOLIA_SELECTOR,
                sender: _getContractAddress(ETH_SEPOLIA_CHAIN_ID, "TLDCcipSender")
            });
            receiver.toggleAllowedSender({
                chainSelector: OP_SEPOLIA_SELECTOR,
                sender: _getContractAddress(OP_SEPOLIA_CHAIN_ID, "TLDCcipSender")
            });
            receiver.toggleAllowedSender({
                chainSelector: POL_AMOY_SELECTOR,
                sender: _getContractAddress(POL_AMOY_CHAIN_ID, "TLDCcipSender")
            });
        } else {
            receiver.toggleAllowedSender({
                chainSelector: AVAX_MAINNET_SELECTOR,
                sender: _getContractAddress(AVAX_MAINNET_CHAIN_ID, "TLDCcipSender")
            });
            receiver.toggleAllowedSender({
                chainSelector: BASE_MAINNET_SELECTOR,
                sender: _getContractAddress(BASE_MAINNET_CHAIN_ID, "TLDCcipSender")
            });
            receiver.toggleAllowedSender({
                chainSelector: ETH_MAINNET_SELECTOR,
                sender: _getContractAddress(ETH_MAINNET_CHAIN_ID, "TLDCcipSender")
            });
            receiver.toggleAllowedSender({
                chainSelector: OP_MAINNET_SELECTOR,
                sender: _getContractAddress(OP_MAINNET_CHAIN_ID, "TLDCcipSender")
            });
            receiver.toggleAllowedSender({
                chainSelector: POL_MAINNET_SELECTOR,
                sender: _getContractAddress(POL_MAINNET_CHAIN_ID, "TLDCcipSender")
            });
        }

        vm.stopBroadcast();
    }
}
