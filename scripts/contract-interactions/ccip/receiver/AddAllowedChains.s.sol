// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {TLDCcipReceiver} from "contracts/chainlink/ccip/TLDCcipReceiver.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract AddAllowedChains is Script, DeployConstants, GetContractAddress {
    function run() public {
        uint256 chainId = block.chainid;

        address receiverAddress = _getContractAddress(chainId, "TLDCcipReceiver");

        TLDCcipReceiver receiver = TLDCcipReceiver(receiverAddress);

        vm.startBroadcast();

        if (chainId == ARB_SEPOLIA_CHAIN_ID) {
            receiver.toggleAllowedSourceChain({sourceChainSelector: AVAX_FUJI_SELECTOR});
            receiver.toggleAllowedSourceChain({sourceChainSelector: BASE_SEPOLIA_SELECTOR});
            receiver.toggleAllowedSourceChain({sourceChainSelector: ETH_SEPOLIA_SELECTOR});
            receiver.toggleAllowedSourceChain({sourceChainSelector: OP_SEPOLIA_SELECTOR});
            receiver.toggleAllowedSourceChain({sourceChainSelector: POL_AMOY_SELECTOR});
        } else {
            receiver.toggleAllowedSourceChain({sourceChainSelector: AVAX_MAINNET_SELECTOR});
            receiver.toggleAllowedSourceChain({sourceChainSelector: BASE_MAINNET_SELECTOR});
            receiver.toggleAllowedSourceChain({sourceChainSelector: ETH_MAINNET_SELECTOR});
            receiver.toggleAllowedSourceChain({sourceChainSelector: OP_MAINNET_SELECTOR});
            receiver.toggleAllowedSourceChain({sourceChainSelector: POL_MAINNET_SELECTOR});
        }

        vm.stopBroadcast();
    }
}
