// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {TLDCcipSender} from "contracts/helpers/chainlink/ccip/TLDCcipSender.sol";
import {CcipHelperConfig} from "deploy/utils/configs/CcipHelperConfig.s.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract SetNewReceiverContract is Script, DeployConstants, GetContractAddress {
    function run() public {
        uint256 chainId = block.chainid;

        address senderAddress = _getContractAddress(chainId, "TLDCcipSender");
        address receiverAddress;

        if (
            chainId == AVAX_FUJI_CHAIN_ID ||
            chainId == BASE_SEPOLIA_CHAIN_ID ||
            chainId == ETH_SEPOLIA_CHAIN_ID ||
            chainId == OP_SEPOLIA_CHAIN_ID ||
            chainId == POL_AMOY_CHAIN_ID
        ) {
            receiverAddress = _getContractAddress(ARB_SEPOLIA_CHAIN_ID, "TLDCcipReceiver");
        } else {
            receiverAddress = _getContractAddress(ARB_MAINNET_CHAIN_ID, "TLDCcipReceiver");
        }

        TLDCcipSender sender = TLDCcipSender(payable(senderAddress));

        vm.startBroadcast();

        sender.setReceiverContract(receiverAddress);

        vm.stopBroadcast();
    }
}
